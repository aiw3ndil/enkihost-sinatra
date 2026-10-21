# frozen_string_literal: true

# Keeps a user's running resources within their plan. After a downgrade, whatever
# no longer fits (apps of a kind the plan does not allow, apps or databases over its
# limits) is stopped and marked suspended; nothing is deleted. When the plan allows
# them again (e.g. the user pays again), they are started back up. Older resources
# are kept running first.
class PlanEnforcementService
  def initialize(user)
    @user = user
    @limits = user.limits
  end

  def call
    apps = @user.apps.order(:created_at, :id).to_a
    allowed_apps = apps.select { |app| @limits[:allowed_kinds].include?(app.kind) }
                       .first(app_limit)
    allowed_app_ids = allowed_apps.map(&:id)

    addons = Addon.where(app_id: apps.map(&:id)).order(:created_at, :id).to_a
    kept = Hash.new(0)
    allowed_addons = addons.select do |addon|
      next false unless allowed_app_ids.include?(addon.app_id)
      next false if kept[addon.kind] >= (@limits[:"max_#{addon.kind}"] || 0)

      kept[addon.kind] += 1
    end

    (apps - allowed_apps).each { |app| suspend_app(app) }
    (addons - allowed_addons).each { |addon| suspend_addon(addon) }
    # Databases first, so resumed apps find them running
    allowed_addons.each { |addon| resume_addon(addon) }
    allowed_apps.each { |app| resume_app(app) }
  end

  private

  # first(n) needs an Integer; god mode has no limit
  def app_limit
    max = @limits[:max_apps]
    max == Float::INFINITY ? @user.apps.count : max.to_i
  end

  def suspend_app(app)
    return if app.suspended?

    if app.coolify_uuid.present?
      CoolifyService.new.stop_application(app.coolify_uuid)
    elsif (container_name = app.current_container_name)
      system(DockerService.docker_bin, 'stop', container_name, out: File::NULL, err: File::NULL)
    end
    app.update_columns(suspended_at: Time.current, runtime_status: 'down', updated_at: Time.current)
    Rails.logger.info "[PlanEnforcement] Suspended app #{app.id} of user #{@user.id} (#{@user.plan})"
  rescue StandardError => e
    warn "[PlanEnforcement] Could not suspend app #{app.id}: #{e.message}"
  end

  def resume_app(app)
    return unless app.suspended?

    started = if app.coolify_uuid.present?
                CoolifyService.new.start_application(app.coolify_uuid)
              elsif (container_name = app.current_container_name)
                system(DockerService.docker_bin, 'start', container_name, out: File::NULL, err: File::NULL)
              end
    app.update_columns(suspended_at: nil, runtime_status: started ? 'running' : 'down', updated_at: Time.current)
    Rails.logger.info "[PlanEnforcement] Resumed app #{app.id} of user #{@user.id} (#{@user.plan})"
  rescue StandardError => e
    warn "[PlanEnforcement] Could not resume app #{app.id}: #{e.message}"
  end

  def suspend_addon(addon)
    return if addon.suspended?

    AddonService.new(addon).stop
    addon.update_columns(suspended_at: Time.current, status: 'stopped', updated_at: Time.current)
    Rails.logger.info "[PlanEnforcement] Suspended addon #{addon.id} of user #{@user.id} (#{@user.plan})"
  rescue StandardError => e
    warn "[PlanEnforcement] Could not suspend addon #{addon.id}: #{e.message}"
  end

  def resume_addon(addon)
    return unless addon.suspended?

    started = AddonService.new(addon).start
    addon.update_columns(suspended_at: nil, status: started ? 'running' : 'stopped', updated_at: Time.current)
    Rails.logger.info "[PlanEnforcement] Resumed addon #{addon.id} of user #{@user.id} (#{@user.plan})"
  rescue StandardError => e
    warn "[PlanEnforcement] Could not resume addon #{addon.id}: #{e.message}"
  end
end
