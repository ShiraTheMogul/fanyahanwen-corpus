# frozen_string_literal: true

Rails.application.config.x.corpus_root =
  ENV.fetch("CORPUS_ROOT") { Rails.root.join("..", "corpus").to_s }
