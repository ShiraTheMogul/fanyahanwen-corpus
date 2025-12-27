Rails.application.routes.draw do
	root "home#index"

	resources :characters, only: [:index, :show] do
	  get :preview, on: :member
	end

	get "/tools", to: "tools#index", as: :tools
	get "/dictionary", to:"characters#index"
	get "/corpus_viewer(/*path)", to: "corpus_viewer#show", as: :corpus_viewer, format: false # stop a silly attempt to output a txt file
	
	post "/preferences", to: "preferences#update", as: :preferences

end
