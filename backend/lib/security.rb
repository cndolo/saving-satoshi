# frozen_string_literal: true
require 'bcrypt'
require 'digest'
require 'securerandom'

module CourseBackend
  module Security
    module_function

    def username(value)
      unless value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/)
        raise ArgumentError, 'Username: 1–64 ASCII letters, numbers, dots, underscores or hyphens'
      end
      value.downcase
    end

    # The unchanged Saving Satoshi UI uses a random secp256k1 private key as its password.
    # This is an application login secret, never a wallet key or a runner input.
    def login_key(value)
      order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
      unless value.is_a?(String) && value.match?(/\A[0-9a-fA-F]{64}\z/) && value.to_i(16).between?(1, order - 1)
        raise ArgumentError, 'Login key: exactly 64 hexadecimal characters, a valid nonzero secp256k1 key'
      end
      value.downcase
    end

    def key_lookup(value)
      Digest::SHA256.hexdigest(login_key(value))
    end

    def validate_password(value)
      unless value.is_a?(String) && value.length >= 12 && value.bytesize <= 72 && !value.include?("\0")
        raise ArgumentError, 'Password: at least 12 characters and at most 72 UTF-8 bytes, without NUL'
      end
      value
    end

    def password_hash(value)
      BCrypt::Password.create(validate_password(value), cost: 12).to_s
    end

    def valid_password?(hash, value)
      return false unless value.is_a?(String) && value.bytesize.between?(1, 72) && !value.include?("\0")
      BCrypt::Password.new(hash) == value
    end

    def token_hash(token)
      Digest::SHA256.hexdigest(token)
    end
  end

  # Small, bounded, process-local throttle. Run one Puma worker (threads are fine).
  class LoginLimiter
    def initialize(limit: 10, window: 300)
      @limit, @window = limit, window
      @entries = {}
      @mutex = Mutex.new
    end

    def allow?(key)
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @entries.delete_if { |_key, entry| entry[1] <= now }
        @entries.shift if @entries.size >= 10_000 && !@entries.key?(key)
        entry = (@entries[key] ||= [0, now + @window])
        entry[0] += 1
        entry[0] <= @limit
      end
    end
  end
end
