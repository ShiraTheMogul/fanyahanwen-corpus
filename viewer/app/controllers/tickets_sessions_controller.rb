class TicketsSessionsController < ApplicationController
  # Session-based login for the moderator UI.
  #
  # Browsers cannot easily attach custom headers (like X-Moderator-Token) to
  # normal page navigations, so for the HTML UI we store the plaintext token in
  # the Rails session and validate it server-side.

  def new
  end

  def create
    token = params[:token].to_s.strip
    if token.blank?
      flash.now[:alert] = "Token is required."
      return render :new, status: 422
    end

    auth = EditTickets::ModeratorAuth.verify_plaintext(token, scopes: %w[review_only apply_patch admin])
    if auth.nil?
      flash.now[:alert] = "Invalid token."
      return render :new, status: 401
    end

    session[:moderator_token] = token
    redirect_to tickets_path
  end

  def destroy
    session.delete(:moderator_token)
    redirect_to tickets_login_path
  end
end
