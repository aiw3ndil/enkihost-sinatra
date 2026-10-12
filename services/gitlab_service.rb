require 'faraday'

class GitlabService
  BASE_URL = 'https://gitlab.com'.freeze
  OAUTH_SCOPES = 'api read_user read_repository'.freeze

  class OAuthError < StandardError; end

  def self.client_for_token(token)
    Gitlab.client(endpoint: "#{BASE_URL}/api/v4", private_token: token, httparty: { timeout: 10 })
  end

  # Must be registered in the GitLab OAuth application. The API callback always receives the
  # code, so the redirect URI a client asks for is ignored.
  def self.redirect_uri
    ENV['GITLAB_REDIRECT_URI'].presence || 'https://api.enkihost.com/api/v1/gitlab/callback'
  end

  def self.authorize_url(state, redirect_uri)
    query = URI.encode_www_form(
      client_id: ENV['GITLAB_CLIENT_ID'],
      redirect_uri: redirect_uri,
      response_type: 'code',
      scope: OAUTH_SCOPES,
      state: state
    )
    "#{BASE_URL}/oauth/authorize?#{query}"
  end

  # GitLab requires the same redirect_uri used in the authorize request.
  def self.exchange_code(code, redirect_uri)
    request_token(grant_type: 'authorization_code', code: code, redirect_uri: redirect_uri)
  end

  # GitLab OAuth access tokens expire after two hours and every refresh rotates the refresh token.
  def self.refresh_token(refresh_token)
    request_token(grant_type: 'refresh_token', refresh_token: refresh_token, redirect_uri: redirect_uri)
  end

  # Revoking the OAuth token makes GitLab ask for authorization again on the next connect.
  # Failures are only logged: the connection is removed locally either way.
  def self.revoke_token(token)
    return if token.blank?

    Faraday.post("#{BASE_URL}/oauth/revoke", {
      client_id: ENV['GITLAB_CLIENT_ID'],
      client_secret: ENV['GITLAB_CLIENT_SECRET'],
      token: token
    }) do |req|
      req.options.timeout = 10
      req.options.open_timeout = 5
    end
  rescue StandardError => e
    warn "[GitlabService] Token revocation failed: #{e.message}"
  end

  def self.request_token(params)
    response = Faraday.post("#{BASE_URL}/oauth/token", params.merge(
      client_id: ENV['GITLAB_CLIENT_ID'],
      client_secret: ENV['GITLAB_CLIENT_SECRET']
    ), { 'Accept' => 'application/json' }) do |req|
      req.options.timeout = 10
      req.options.open_timeout = 5
    end

    data = JSON.parse(response.body) rescue {}
    return data if data['access_token'].present?
    # OAuthError means GitLab rejected the grant; anything else may be a transient outage.
    raise OAuthError, (data['error_description'] || data['error']) if data['error'].present?

    raise "GitLab token endpoint returned HTTP #{response.status}"
  end

  def initialize(user)
    @user = user
    @client = self.class.client_for_token(@user.fresh_gitlab_token!)
  end

  def projects
    @client.projects(membership: true, order_by: 'last_activity_at', sort: 'desc', per_page: 100).map do |project|
      attrs = project.to_h
      {
        id: attrs['id'],
        name: attrs['name'],
        full_name: attrs['path_with_namespace'],
        html_url: attrs['web_url'],
        git_url: attrs['http_url_to_repo'],
        description: attrs['description'],
        default_branch: attrs['default_branch'],
        private: attrs['visibility'] != 'public'
      }
    end
  end

  def create_webhook(project_path, callback_url, secret = nil)
    secret ||= Rails.application.credentials.fetch(:gitlab_webhook_token, 'dummy_token')
    @client.add_project_hook(project_path, callback_url, {
      push_events: true,
      token: secret
    })
  rescue Gitlab::Error::UnprocessableEntity => e
    Rails.logger.error("GitLab Webhook Error: #{e.message}")
  end
end
