# frozen_string_literal: true

# Active Record Encryption needs three secrets:
#   - primary_key
#   - deterministic_key
#   - key_derivation_salt
#
# If you run `bin/rails db:encryption:init`, Rails will print values you can put
# into credentials under `active_record_encryption:`.
#
# This project prefers "works out of the box" in development.
# So:
#   1) If credentials provide keys, we use them.
#   2) Otherwise we derive stable keys from secret_key_base.
#
# Deriving from secret_key_base keeps encryption working across restarts as long
# as secret_key_base is stable (it usually is). In production, you SHOULD set
# explicit keys in credentials.

require "base64"

module ActiveRecordEncryptionKeys
  module_function

  def derive_key(label, length: 32)
    # ActiveSupport::KeyGenerator derives cryptographic keys from a secret.
    # "label" acts like a salt namespace.
    generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base, iterations: 2**16)
    bytes = generator.generate_key("fanyahanwen:ar_encryption:#{label}", length)
    Base64.strict_encode64(bytes)
  end

  def configured_keys
    creds = Rails.application.credentials
    h = creds.respond_to?(:dig) ? creds.dig(:active_record_encryption) : nil
    return {} unless h.is_a?(Hash)

    {
      primary_key: h[:primary_key].presence,
      deterministic_key: h[:deterministic_key].presence,
      key_derivation_salt: h[:key_derivation_salt].presence,
    }.compact
  end
end

keys = ActiveRecordEncryptionKeys.configured_keys

if keys[:primary_key].blank? || keys[:deterministic_key].blank? || keys[:key_derivation_salt].blank?
  # Derive missing keys from secret_key_base.
  keys[:primary_key] ||= ActiveRecordEncryptionKeys.derive_key("primary")
  keys[:deterministic_key] ||= ActiveRecordEncryptionKeys.derive_key("deterministic")
  keys[:key_derivation_salt] ||= ActiveRecordEncryptionKeys.derive_key("salt")

  # Keep logs low-noise in production.
  unless Rails.env.production?
    Rails.logger.warn("[active_record_encryption] Using keys derived from secret_key_base. Set credentials.active_record_encryption.* for production.")
  end
end

ActiveRecord::Encryption.configure(
  primary_key: keys[:primary_key],
  deterministic_key: keys[:deterministic_key],
  key_derivation_salt: keys[:key_derivation_salt],
)
