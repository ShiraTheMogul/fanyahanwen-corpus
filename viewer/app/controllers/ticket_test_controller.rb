class TicketTestController < ApplicationController
  # This page is intentionally meant for manual testing of the ticket submission system.
  # It is disabled by default in production.
  #
  # To enable in production temporarily, set:
  #   ENABLE_TICKET_TEST_PAGE=1
  before_action :ensure_enabled

  def index
  end

  private

  def ensure_enabled
    return if Rails.env.development? || Rails.env.test?
    return if ENV["ENABLE_TICKET_TEST_PAGE"].to_s == "1"

    raise ActionController::RoutingError, "Not Found"
  end
end
