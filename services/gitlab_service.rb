class GitlabService
  def initialize(user)
    @user = user
    @client = Gitlab.client(endpoint: 'https://gitlab.com/api/v4', private_token: @user.gitlab_token)
  end

  def projects
    @client.projects(membership: true, simple: true, order_by: 'updated_at').map do |project|
      {
        name: project.name,
        full_name: project.path_with_namespace,
        git_url: project.http_url_to_repo,
        description: project.description,
        default_branch: project.default_branch
      }
    end
  rescue Gitlab::Error::Unauthorized
    []
  end

  def create_webhook(project_id, callback_url, secret = nil)
    secret ||= Rails.application.credentials.fetch(:gitlab_webhook_token, 'dummy_token')
    @client.add_project_hook(project_id, callback_url, {
      push_events: true,
      token: secret
    })
  rescue Gitlab::Error::UnprocessableEntity => e
    Rails.logger.error("GitLab Webhook Error: #{e.message}")
  end
end
