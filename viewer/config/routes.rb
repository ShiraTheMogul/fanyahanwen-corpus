Rails.application.routes.draw do
	root "home#index"

    get "/characters/structure", to: "character_structures#index", as: :character_structure_search
    get "/characters/input_codes", to: "character_input_codes#index", as: :character_input_codes

	resources :characters, only: [:index, :show] do
	  get :preview, on: :member
	end

	get  "/tools",          to: "tools#index",       as: :tools
	post "/tools/numerals", to: "tools#numerals",    as: :tools_numerals
	post "/tools/cangjie",  to: "tools#cangjie",     as: :tools_cangjie
	post "/tools/lunar", to: "tools#lunar", as: :tools_lunar
	post "/tools/phonetic/mandarin", to: "tools#phonetic_mandarin", as: :tools_phonetic_mandarin
	post "/tools/phonetic/cantonese", to: "tools#phonetic_cantonese", as: :tools_phonetic_cantonese
	
	# Normalized historical dictionary catalogue
	get "/dictionary/catalogue", to: "dictionary_catalogue#index", as: :dictionary_catalogue
	get "/dictionary/catalogue/:corpus_work_id/sections/:section_sequence/entries", to: "dictionary_catalogue#entries", as: :dictionary_catalogue_section_entries
	get "/dictionary/catalogue/:corpus_work_id/sections/:section_sequence", to: "dictionary_catalogue#section", as: :dictionary_catalogue_section
	get "/dictionary/catalogue/:corpus_work_id/entries/:entry_sequence", to: "dictionary_catalogue#entry", as: :dictionary_catalogue_entry
	get "/dictionary/catalogue/:corpus_work_id", to: "dictionary_catalogue#show", as: :dictionary_catalogue_work
	
	# search system 
	  get  "/corpus/search", to: "corpus_search#index", as: :corpus_search
	  post "/corpus/search/prepare", to: "corpus_search#prepare", as: :prepare_corpus_search
	  get  "/corpus/search/prepared/:id", to: "corpus_search#prepared", as: :prepared_corpus_search
	  get  "/corpus/search/prepared/:id/download", to: "corpus_search#download", as: :download_prepared_corpus_search
	  post "/corpus/search/prepared/:id/cancel", to: "corpus_search#cancel", as: :cancel_prepared_corpus_search
	
	get "/corpus_viewer(/*path)", to: "corpus_viewer#show", as: :corpus_viewer, format: false # stop a silly attempt to output a txt file
	
	# corpus annotation stuff
	get  "/corpus_annotations", to: "corpus_annotations#show"
	post "/corpus_annotations", to: "corpus_annotations#update"
	
	# activity!
	get "/corpus/activity", to: "home#activity", as: :corpus_activity
	
	get "/fun", to: "fun#index", as: :fun # Minigame section
	
	# Literary Chinese Grammar Wiki
	get  "/grammar",              to: "grammar#index",    as: :grammar
	post "/grammar/preview",      to: "grammar#preview",  as: :preview_grammar_entry
	get  "/grammar/:id/template", to: "grammar#template", as: :grammar_entry_template
	get  "/grammar/:id",          to: "grammar#show",     as: :grammar_entry
	
	  # Fanya Hanwen Historical Atlas
	get  "/atlas",              to: "atlas#index",    as: :atlas
	post "/atlas/preview",      to: "atlas#preview",  as: :preview_atlas_entry
	get  "/atlas/:id/template", to: "atlas#template", as: :atlas_entry_template
	get  "/atlas/:id",          to: "atlas#show",     as: :atlas_entry
	
	# The Textbook is currently unused.
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
	# Moderator UI (HTML) for reviewing and applying edit tickets.
	get    "/tickets/login",  to: "tickets_sessions#new",     as: :tickets_login
	post   "/tickets/login",  to: "tickets_sessions#create"
	delete "/tickets/logout", to: "tickets_sessions#destroy", as: :tickets_logout
	
	get "/ticket_access", to: "tickets_access#index", as: :ticket_access
	
	resources :tickets, param: :public_id, only: %i[index show] do
		member do
			post :approve
			post :reject
			post :close
			post :apply_patch
			post :create_message
		end
	end

  resources :moderator_tokens, only: %i[index new create] do
    post :revoke, on: :member
  end

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
	  post "/tickets/resolve_key", to: "edit_tickets#resolve_key"
	end
	
	get "/ticket_test", to: "ticket_test#index"
	
	# fun
	get "/fun/xuanji", to: "xuanji#show", as: :xuanji
	post "/fun/xuanji/sync_colors", to: "xuanji#sync_colors", as: :xuanji_sync_colors
	post "/fun/xuanji/phoneticize", to: "xuanji#phoneticize", as: :xuanji_phoneticize
	get "/fun/transcription", to: "transcription#show", as: :transcription
	get "/fun/deconstruction",
		to: "character_games#deconstruction",
		as: :character_deconstruction

	get "/fun/components",
		to: "character_games#components",
		as: :character_components

	get "/fun/make-a-character",
		to: "character_games#construction",
		as: :character_construction
		
	get  "/fun/chengyu-jielong",
		 to: "chengyu_games#jielong",
		 as: :chengyu_jielong

	post "/fun/chengyu-jielong/start",
		 to: "chengyu_games#start"

	post "/fun/chengyu-jielong/turn",
		 to: "chengyu_games#turn"

	post "/fun/chengyu-jielong/alternatives",
		 to: "chengyu_games#alternatives"
	
	get "/xiangqi", to: "xiangqi#show"
	post "/xiangqi/theme", to: "xiangqi#theme"
	get "/xiangqi/legal_moves", to: "xiangqi#legal_moves"
	post "/xiangqi/move", to: "xiangqi#move"
	post "/xiangqi/view", to: "xiangqi#view_mode"
	post "/xiangqi/undo", to: "xiangqi#undo"
	post "/xiangqi/reset", to: "xiangqi#reset"

	post "/preferences", to: "preferences#update", as: :preferences

end
