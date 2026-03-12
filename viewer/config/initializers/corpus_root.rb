# frozen_string_literal: true
#
# Where the big corpus lives on disk.
# Repo layout is:
#   fanyahanwen-corpus/
#     viewer/   (Rails app; Rails.root)
#     corpus/   (multi-GB texts; NOT inside the Rails app dir)
#
# The text-edit ticket endpoint reads files from this root.
Rails.configuration.x.corpus_root ||= Rails.root.join("..", "corpus")
