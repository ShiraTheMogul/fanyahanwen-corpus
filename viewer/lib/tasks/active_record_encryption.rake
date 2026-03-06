# frozen_string_literal: true

namespace :active_record_encryption do
  desc "Print Active Record encryption keys derived from secret_key_base (useful for credentials setup)"
  task :print_derived_keys => :environment do
    require "base64"

    generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base, iterations: 2**16)

    def derive(generator, label, length: 32)
      bytes = generator.generate_key("fanyahanwen:ar_encryption:#{label}", length)
      Base64.strict_encode64(bytes)
    end

    puts "active_record_encryption:"
    puts "  primary_key: #{derive(generator, 'primary')}"
    puts "  deterministic_key: #{derive(generator, 'deterministic')}"
    puts "  key_derivation_salt: #{derive(generator, 'salt')}"
  end
end
