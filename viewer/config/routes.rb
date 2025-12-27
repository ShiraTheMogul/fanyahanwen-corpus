Rails.application.routes.draw do
	root "home#index"

	resources :characters, only: [:index, :show] do
	  get :preview, on: :member
	end

	get "/tools", to: "tools#index", as: :tools
	get "/dictionary", to:"characters#index"
	get "/corpus_viewer", to: "corpus_viewer#index", as: :corpus_viewer
	
	post "/preferences", to: "preferences#update", as: :preferences
end
