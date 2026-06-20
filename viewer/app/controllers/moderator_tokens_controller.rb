class ModeratorTokensController < ApplicationController
  before_action :require_admin!

  def index
    @tokens = TicketModeratorToken.order(created_at: :desc).limit(200)
  end

  def new
    # form
  end

  def create
    name = params[:name].to_s.strip
    scope = params[:scope].to_s.strip

    if name.blank?
      flash.now[:alert] = "Name is required."
      return render :new, status: 422
    end

    allowed_scopes = %w[review_only apply_patch admin]
    unless allowed_scopes.include?(scope)
      flash.now[:alert] = "Scope must be one of: #{allowed_scopes.join(', ')}"
      return render :new, status: 422
    end

    record, plaintext = EditTickets::ModeratorTokenIssuer.issue!(name: name, scope: scope)
    @issued_record = record
    @issued_plaintext = plaintext
    render :created
  end

  def revoke
    token = TicketModeratorToken.find(params[:id])
    token.update!(revoked_at: Time.current)
    redirect_to moderator_tokens_path, notice: "Moderator token revoked."
  end

  private
  def require_admin!
    token = session[:moderator_token].to_s
    @moderator = EditTickets::ModeratorAuth.verify_plaintext(token, scopes: %w[admin])
    return if @moderator.present?

    redirect_to tickets_login_path
  end
end
