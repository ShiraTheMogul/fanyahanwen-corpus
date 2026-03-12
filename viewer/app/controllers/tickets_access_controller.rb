class TicketsAccessController < ApplicationController
  # Public, no-account ticket access shell.
  # The actual ticket read/write auth still happens through the submitter-key API.
  def index
  end
end
