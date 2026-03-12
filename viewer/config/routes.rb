Rails.application.routes.draw do
	root "home#index"

	resources :characters, only: [:index, :show] do
	  get :preview, on: :member
	end

	get  "/tools",          to: "tools#index",       as: :tools
	post "/tools/numerals", to: "tools#numerals",    as: :tools_numerals
	post "/tools/cangjie",  to: "tools#cangjie",     as: :tools_cangjie
	post "/tools/lunar", to: "tools#lunar", as: :tools_lunar
	post "/tools/phonetic/mandarin", to: "tools#phonetic_mandarin", as: :tools_phonetic_mandarin
	post "/tools/phonetic/cantonese", to: "tools#phonetic_cantonese", as: :tools_phonetic_cantonese

	# Kangxi radicals browser
	get "/dictionary/radicals", to: "kangxi_radicals#index", as: :dictionary_radicals
	get "/dictionary/radicals/:number", to: "kangxi_radicals#show", as: :dictionary_radical
	get "/dictionary/radicals/:number/chars", to: "kangxi_radicals#chars", as: :dictionary_radical_chars
	
	# Shuowen category browser
	get "/dictionary/shuowen", to: "shuowen_components#index", as: :dictionary_components
	get "/dictionary/shuowen/:number", to: "shuowen_components#show", as: :dictionary_component
	get "/dictionary/shuowen/:number/chars", to: "shuowen_components#chars", as: :dictionary_component_chars
	
	# Guangyun category browser (tone + rhyme)
	get "/dictionary/guangyun", to: "guangyun_categories#index", as: :dictionary_guangyun
	get "/dictionary/guangyun/:category", to: "guangyun_categories#show", as: :dictionary_guangyun_category
	get "/dictionary/guangyun/:category/chars", to: "guangyun_categories#chars", as: :dictionary_guangyun_category_chars
	
	get "/corpus_viewer(/*path)", to: "corpus_viewer#show", as: :corpus_viewer, format: false # stop a silly attempt to output a txt file
	
	# config/routes.rb
	get  "/corpus_annotations", to: "corpus_annotations#show"
	post "/corpus_annotations", to: "corpus_annotations#update"
	
	get "/fun", to: "fun#index", as: :fun # Minigame section

	# Textbook (interactive lessons)
	get  "/textbook", to: "textbook#index", as: :textbook

	# Textbook editor (authoring UI)
	get  "/textbook/editor", to: "textbook_editor#index", as: :textbook_editor
	get  "/textbook/editor/new", to: "textbook_editor#new", as: :new_textbook_lesson
	get  "/textbook/editor/:slug/edit", to: "textbook_editor#edit", as: :edit_textbook_lesson
	post "/textbook/editor", to: "textbook_editor#create", as: :create_textbook_lesson
	patch "/textbook/editor/:slug", to: "textbook_editor#update", as: :update_textbook_lesson
	post "/textbook/editor/preview", to: "textbook_editor#preview", as: :preview_textbook_lesson

	# Lesson pages (this must come after the editor routes)
	get  "/textbook/:slug", to: "textbook#show", as: :textbook_lesson

	# Deterministic exercise APIs
	post "/textbook/api/format_numeral", to: "textbook_api#format_numeral"
	post "/textbook/api/parse_numeral",  to: "textbook_api#parse_numeral"
	
	# Edit submissions and tickets
	#
	# Moderator UI (HTML) for reviewing and applying edit tickets.
	get    "/tickets/login",  to: "tickets_sessions#new",     as: :tickets_login
	post   "/tickets/login",  to: "tickets_sessions#create"
	delete "/tickets/logout", to: "tickets_sessions#destroy", as: :tickets_logout

	resources :tickets, param: :public_id, only: %i[index show] do
		member do
			post :approve
			post :reject
			post :close
			post :apply_patch
			post :create_message
		end
	end

	resources :moderator_tokens, only: %i[index new create]

	namespace :api do
	  get  "/tickets", to: "edit_tickets#index"
	  post "/tickets", to: "edit_tickets#create"
	  post "/tickets/text_edit", to: "edit_tickets#create_text_edit"
	  get  "/tickets/:public_id", to: "edit_tickets#show"

	  post "/tickets/:public_id/messages", to: "edit_tickets#create_message"

	  get  "/tickets/:public_id/evidence/:attachment_id", to: "edit_tickets#download_evidence"

	  post "/tickets/:public_id/approve", to: "edit_tickets#approve"
	  post "/tickets/:public_id/reject",  to: "edit_tickets#reject"
	  post "/tickets/:public_id/close",   to: "edit_tickets#close"
	end
	
	get "/ticket_test", to: "ticket_test#index"
	
	# fun
	get "/fun/xuanji", to: "xuanji#show", as: :xuanji
	post "/fun/xuanji/sync_colors", to: "xuanji#sync_colors", as: :xuanji_sync_colors
	post "/fun/xuanji/phoneticize", to: "xuanji#phoneticize", as: :xuanji_phoneticize
	
	get "/xiangqi", to: "xiangqi#show"
	post "/xiangqi/theme", to: "xiangqi#theme"
	get "/xiangqi/legal_moves", to: "xiangqi#legal_moves"
	post "/xiangqi/move", to: "xiangqi#move"
	post "/xiangqi/view", to: "xiangqi#view_mode"
	post "/xiangqi/undo", to: "xiangqi#undo"
	post "/xiangqi/reset", to: "xiangqi#reset"

	post "/preferences", to: "preferences#update", as: :preferences

end
