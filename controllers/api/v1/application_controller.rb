# frozen_string_literal: true

module Api
  module V1
    class ApplicationController < ::ApplicationController
      include Pundit::Authorization if defined?(Pundit::Authorization)

      def policy_scope(scope)
        super([:api, :v1, scope])
      rescue Pundit::NotDefinedError
        super(scope)
      end

      def authorize(record, query = nil, policy_class: nil)
        query ||= "#{action_name}?"
        if policy_class
          super(record, query, policy_class: policy_class)
        else
          begin
            super([:api, :v1, record], query)
          rescue Pundit::NotDefinedError
            super(record, query)
          end
        end
      end
    end
  end
end
