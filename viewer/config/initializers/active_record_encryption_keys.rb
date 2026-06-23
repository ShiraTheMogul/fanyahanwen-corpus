# frozen_string_literal: true

require "base64"

module ActiveRecordEncryptionKeys
  module_function

  ENV_KEYS = {
    primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
    deterministic_key: "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
    key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
  }.freeze

  def derive_key(label, length: 32)
    generator = ActiveSupport::KeyGenerator.new(
      Rails.application.secret_key_base,
      iterations: 2**16
    )
    bytes = generator.generate_key("fanyahanwen:ar_encryption:#{label}", length)
    Base64.strict_encode64(bytes)
  end

  def environment_keys
    ENV_KEYS.to_h { |name, variable| [name, ENV[variable].presence] }.compact
  end

  def credential_keys
    credentials = Rails.application.credentials
    values = credentials.respond_to?(:dig) ? credentials.dig(:active_record_encryption) : nil
    return {} unless values.is_a?(Hash)

    {
      primary_key: values[:primary_key].presence,
      deterministic_key: values[:deterministic_key].presence,
      key_derivation_salt: values[:key_derivation_salt].presence
    }.compact
  rescue ActiveSupport::EncryptedFile::MissingKeyError, ActiveSupport::MessageEncryptor::InvalidMessage
    {}
  end
end

keys = ActiveRecordEncryptionKeys.credential_keys.merge(
  ActiveRecordEncryptionKeys.environment_keys
)

keys[:primary_key] ||= ActiveRecordEncryptionKeys.derive_key("primary")
keys[:deterministic_key] ||= ActiveRecordEncryptionKeys.derive_key("deterministic")
keys[:key_derivation_salt] ||= ActiveRecordEncryptionKeys.derive_key("salt")

ActiveRecord::Encryption.configure(
  primary_key: keys.fetch(:primary_key),
  deterministic_key: keys.fetch(:deterministic_key),
  key_derivation_salt: keys.fetch(:key_derivation_salt)
)
