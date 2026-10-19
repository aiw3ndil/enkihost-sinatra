require 'open3'
require 'shellwords'
require 'tempfile'
require 'zlib'

# Downloads and imports PostgreSQL addon databases. Every pg_dump, pg_restore and
# psql runs inside the addon's own container, so the client tools always match the
# server version and nothing runs in the API process but the byte shuffling.
class DatabaseTransferService
  class Error < StandardError; end

  CHUNK_SIZE = 64 * 1024
  LOG_LIMIT = 64 * 1024

  # Uploaded files are detected by content, not by extension.
  FORMATS = %w[sql sql_gz custom custom_gz].freeze

  DUMP_FORMATS = {
    'custom' => { flag: '-Fc', extension: 'dump' },
    'sql' => { flag: '-Fp', extension: 'sql' }
  }.freeze

  # Plain SQL statements that refer to roles, databases or privileges of the source
  # server. They are dropped so the dump restores as the addon's own user.
  SKIPPED_STATEMENTS = [
    /\A(CREATE|ALTER|DROP) (ROLE|USER|GROUP)\b/i,
    /\A(CREATE|ALTER|DROP) DATABASE\b/i,
    /\ACOMMENT ON DATABASE\b/i,
    /\A(GRANT|REVOKE)\b/i,
    /\AALTER DEFAULT PRIVILEGES\b/i,
    /\A(SET|RESET) (SESSION AUTHORIZATION|ROLE)\b/i
  ].freeze

  ROLE_NAME = /"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*/
  OWNER_TO = /\bOWNER TO (#{ROLE_NAME})\s*;/
  SCHEMA_AUTHORIZATION = /\A(CREATE SCHEMA\b.*\bAUTHORIZATION )(#{ROLE_NAME})/i
  COPY_FROM_STDIN = /\ACOPY\b.*\bFROM stdin;\s*\z/i

  # A body Rack streams to the client while pg_dump writes it.
  class DumpBody
    def initialize(command)
      @command = command
    end

    def each
      Tempfile.create('pg_dump_err') do |err|
        IO.popen(@command, 'rb', err: err.path) do |io|
          while (chunk = io.read(CHUNK_SIZE))
            yield chunk
          end
        end
        warn "[DatabaseTransfer] pg_dump failed: #{File.read(err.path).strip}" unless $?.success?
      end
    end
  end

  # gzip magic, then pg_dump's custom-format "PGDMP" header.
  def self.detect_format(path)
    head = File.binread(path, 5).to_s
    return detect_inner_format(path, 'gz') if head.start_with?("\x1F\x8B".b)
    return 'custom' if head == 'PGDMP'
    raise Error, 'ZIP archives are not supported, upload a .sql, .sql.gz or .dump file' if head.start_with?('PK')
    raise Error, 'tar dumps are not supported, use pg_dump -Fc or plain SQL' if tar?(path)

    'sql'
  end

  def self.detect_inner_format(path, suffix)
    head = Zlib::GzipReader.open(path) { |gz| gz.read(5) }.to_s
    head == 'PGDMP' ? "custom_#{suffix}" : "sql_#{suffix}"
  rescue Zlib::Error
    raise Error, 'The file looks gzipped but could not be decompressed'
  end

  def self.tar?(path)
    File.size(path) > 262 && File.binread(path, 5, 257) == 'ustar'
  end

  def initialize(addon)
    @addon = addon
  end

  def container
    "enkihost-addon-#{@addon.id}"
  end

  def db_user
    @addon.config['user'].presence || 'enkihost'
  end

  def db_name
    @addon.config['database'].presence || 'main'
  end

  def ready?
    system(docker, 'exec', container, 'pg_isready', '-q', '-U', db_user, '-d', db_name, out: File::NULL, err: File::NULL)
  end

  def dump_body(format)
    DumpBody.new([docker, 'exec', container, 'pg_dump', '-U', db_user, '-d', db_name,
                  '--no-owner', '--no-privileges', DUMP_FORMATS.fetch(format)[:flag]])
  end

  # Copies the uploaded file into the addon container, where the import job reads it.
  def stage(local_path, import)
    remote = remote_path(import)
    _out, status = Open3.capture2e(docker, 'cp', local_path, "#{container}:#{remote}")
    raise Error, 'Could not copy the dump into the database container' unless status.success?

    remote
  end

  def remove_staged(import)
    system(docker, 'exec', container, 'rm', '-f', remote_path(import), out: File::NULL, err: File::NULL)
  end

  # Restores the staged dump into a scratch database and only swaps it in for the
  # live one when the whole restore succeeded, so a broken dump never touches it.
  def import!(import, log)
    raise Error, 'The database is not running' unless ready?

    check_disk_space!(import)
    staging = "#{db_name}_import"
    psql_admin("DROP DATABASE IF EXISTS #{ident(staging)} WITH (FORCE)")
    psql_admin("CREATE DATABASE #{ident(staging)} OWNER #{ident(db_user)} TEMPLATE template0")

    begin
      import.format.start_with?('custom') ? restore_custom(import, staging, log) : restore_sql(import, staging, log)
    rescue StandardError
      psql_admin("DROP DATABASE IF EXISTS #{ident(staging)} WITH (FORCE)", raise_on_error: false)
      raise
    end

    swap_in(staging)
    log << "Replaced database #{db_name} with the imported data."
  end

  private

  def docker
    defined?(DockerService) ? DockerService.docker_bin : 'docker'
  end

  def remote_path(import)
    "/tmp/enkihost-import-#{import.id}"
  end

  def ident(name)
    %("#{name.gsub('"', '""')}")
  end

  def literal(value)
    "'#{value.gsub("'", "''")}'"
  end

  # Shell pipeline that writes the staged dump, decompressed, to stdout.
  def read_command(import)
    reader = import.format.end_with?('_gz') ? 'gunzip -c' : 'cat'
    "#{reader} #{Shellwords.escape(remote_path(import))}"
  end

  def psql_admin(sql, raise_on_error: true)
    out, status = Open3.capture2e(docker, 'exec', container, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1',
                                  '-U', db_user, '-d', 'postgres', '-c', sql)
    raise Error, out.strip.presence || "psql failed: #{sql}" if raise_on_error && !status.success?

    status.success?
  end

  def check_disk_space!(import)
    out, status = Open3.capture2e(docker, 'exec', container, 'df', '-Pk', '/var/lib/postgresql/data')
    return unless status.success?

    free = out.lines.last.to_s.split[3].to_i * 1024
    # Compressed dumps expand several times once restored with their indexes.
    needed = import.size.to_i * (import.format == 'sql' ? 3 : 10)
    return if free.zero? || free >= needed

    raise Error, "Not enough disk space to import this dump (#{free >> 20} MB free, about #{needed >> 20} MB needed)"
  end

  def restore_custom(import, staging, log)
    owners = custom_dump_owners(import)
    log << "Objects owned by #{owners.join(', ')} will belong to #{db_user}." if owners.any?

    restore = Shellwords.join(['pg_restore', '-U', db_user, '-d', staging, '--no-owner', '--no-privileges',
                               '--single-transaction', '--exit-on-error'])
    out, status = Open3.capture2e(docker, 'exec', container, 'sh', '-c', "#{read_command(import)} | #{restore}")
    log << out.strip if out.present?
    raise Error, 'pg_restore failed, the database was left unchanged' unless status.success?
  end

  # The owner is the last column of each `pg_restore -l` table of contents entry.
  def custom_dump_owners(import)
    out, status = Open3.capture2e(docker, 'exec', container, 'sh', '-c', "#{read_command(import)} | pg_restore -l")
    raise Error, out.strip.presence || 'The file is not a valid pg_dump archive' unless status.success?

    out.lines.grep(/\A\d+;/).map { |line| line.split.last }.uniq - ['-', db_user]
  end

  def restore_sql(import, staging, log)
    replaced = Set.new
    skipped = 0
    psql = [docker, 'exec', '-i', container, 'psql', '-X', '-q', '-o', '/dev/null', '-v', 'ON_ERROR_STOP=1',
            '--single-transaction', '-U', db_user, '-d', staging]

    status = nil
    read_ok = true
    output = +''
    Open3.popen2e(*psql) do |stdin, out, wait|
      reader = Thread.new { out.each_line { |l| output << l; output = output[-LOG_LIMIT..] if output.size > LOG_LIMIT } }
      begin
        IO.popen([docker, 'exec', container, 'sh', '-c', read_command(import)], 'rb') do |src|
          filter_sql(src, replaced) { |line| line ? stdin.write(line) : skipped += 1 }
        end
        read_ok = $?.success?
      rescue Errno::EPIPE
        # psql stopped at the first error; its output says why.
      ensure
        stdin.close unless stdin.closed?
      end
      status = wait.value
      reader.join
    end

    log << "Objects owned by #{replaced.to_a.join(', ')} now belong to #{db_user}." if replaced.any?
    log << "Skipped #{skipped} role, privilege and psql meta-command statements." if skipped.positive?
    log << output.strip if output.present?
    raise Error, 'The dump could not be read to the end (corrupt or truncated file)' unless read_ok
    raise Error, 'The SQL import failed, the database was left unchanged' unless status.success?
  end

  # Yields each line to send to psql, or nil for each dropped statement. COPY data
  # is passed through untouched.
  def filter_sql(io, replaced)
    in_copy = false
    io.each_line do |line|
      if in_copy
        in_copy = false if line.chomp == '\\.'
        yield line
        next
      end

      stripped = line.lstrip
      if stripped.start_with?('\\') || (stripped.rstrip.end_with?(';') && SKIPPED_STATEMENTS.any? { |re| re.match?(stripped) })
        yield nil
        next
      end

      in_copy = true if COPY_FROM_STDIN.match?(stripped)
      yield replace_roles(line, replaced)
    end
  end

  def replace_roles(line, replaced)
    owner = ident(db_user)
    line = line.sub(OWNER_TO) do
      replaced << Regexp.last_match(1).dup.force_encoding('UTF-8').scrub unless unquote(Regexp.last_match(1)) == db_user
      "OWNER TO #{owner};"
    end
    line.sub(SCHEMA_AUTHORIZATION) { "#{Regexp.last_match(1)}#{owner}" }
  end

  def unquote(role)
    role.start_with?('"') ? role[1..-2].gsub('""', '"') : role.downcase
  end

  # Blocks new connections, kicks the app off the live database and swaps the
  # imported one in. Apps reconnect to the new database under the same name.
  def swap_in(staging)
    previous = "#{db_name}_previous"
    psql_admin("DROP DATABASE IF EXISTS #{ident(previous)} WITH (FORCE)")
    psql_admin("ALTER DATABASE #{ident(db_name)} ALLOW_CONNECTIONS false")

    # Terminated backends take a moment to exit, and the rename fails while they linger.
    renamed = 10.times.any? do |attempt|
      sleep 0.5 if attempt.positive?
      psql_admin("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
                 "WHERE datname = #{literal(db_name)} AND pid <> pg_backend_pid()")
      psql_admin("ALTER DATABASE #{ident(db_name)} RENAME TO #{ident(previous)}", raise_on_error: false)
    end
    unless renamed
      psql_admin("ALTER DATABASE #{ident(db_name)} ALLOW_CONNECTIONS true", raise_on_error: false)
      raise Error, 'Could not disconnect the clients of the live database, try again'
    end

    begin
      psql_admin("ALTER DATABASE #{ident(staging)} RENAME TO #{ident(db_name)}")
    rescue Error
      psql_admin("ALTER DATABASE #{ident(previous)} RENAME TO #{ident(db_name)}", raise_on_error: false)
      psql_admin("ALTER DATABASE #{ident(db_name)} ALLOW_CONNECTIONS true", raise_on_error: false)
      raise
    end
    psql_admin("DROP DATABASE IF EXISTS #{ident(previous)} WITH (FORCE)", raise_on_error: false)
  end
end
