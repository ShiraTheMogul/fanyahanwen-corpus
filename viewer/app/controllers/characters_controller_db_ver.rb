class CharactersController < ApplicationController
  def index
    # This will handle both character and composition search long-term.
    if params[:query].present?
		# <%= form_with url: characters_path, method: :get, local: true do %>
		# call params[:query] == "好" from ^ 
		@characters = SearchCharacter.call(params[:query], params[:search_type])
    else
		@characters = [] #Character.none # Returns empty relation
    end
  end
end
