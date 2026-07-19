#!/usr/bin/env ruby
# frozen_string_literal: true

# Compatibility wrapper. The atlas no longer walks the public corpus folder tree
# or generates request-time hierarchy nodes. Its catalogue is derived from the
# administrator-built corpus manifest instead.

root = File.expand_path("..", __dir__)
command = [File.join(root, "bin", "rails"), "atlas:rebuild_catalogue"]

warn "The folder-hierarchy atlas generator has been retired."
warn "Running the manifest-backed atlas catalogue builder instead:"
warn "  #{command.join(' ')}"

exec(*command)
