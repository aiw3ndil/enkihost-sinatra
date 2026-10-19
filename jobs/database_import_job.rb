class DatabaseImportJob < ApplicationJob
  queue_as :default

  def perform(import_id)
    import = DatabaseImport.find_by(id: import_id)
    return unless import&.pending?

    import.update!(status: :running, started_at: Time.current)
    service = DatabaseTransferService.new(import.addon)
    log = []

    begin
      service.import!(import, log)
      import.update!(status: :success, log: format_log(log), finished_at: Time.current)
    rescue StandardError => e
      warn "[DatabaseImportJob] Import #{import.id} failed: #{e.class}: #{e.message}"
      log << e.message
      import.update!(status: :failed, log: format_log(log), finished_at: Time.current)
    ensure
      service.remove_staged(import)
    end
  end

  private

  def format_log(lines)
    text = lines.join("\n").force_encoding('UTF-8').scrub
    text.size > DatabaseTransferService::LOG_LIMIT ? text[-DatabaseTransferService::LOG_LIMIT..] : text
  end
end
