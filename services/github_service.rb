class GithubService
  def initialize(user)
    @user = user
    @client = Octokit::Client.new(access_token: @user.github_token)
  end

  def repositories
    @client.repositories(nil, sort: 'updated', per_page: 50).map do |repo|
      {
        name: repo.name,
        full_name: repo.full_name,
        git_url: repo.clone_url,
        description: repo.description,
        default_branch: repo.default_branch
      }
    end
  rescue Octokit::Unauthorized
    []
  end

  def create_webhook(repo_full_name, callback_url, secret = nil)
    secret ||= Rails.application.credentials.fetch(:github_webhook_secret, 'dummy_secret')
    config = {
      url: callback_url,
      content_type: 'json',
      secret: secret
    }
    options = {
      events: ['push'],
      active: true
    }
    @client.create_hook(repo_full_name, 'web', config, options)
  rescue Octokit::UnprocessableEntity => e
    # Webhook already exists or repo not found
    Rails.logger.error("GitHub Webhook Error: #{e.message}")
  end
end
