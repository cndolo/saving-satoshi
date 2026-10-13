# frozen_string_literal: true
require 'sinatra/base'
require 'json'
require_relative 'lib/store'
require_relative 'lib/security'
require_relative 'lib/progress'

module CourseBackend
  class App < Sinatra::Base
    set :db_path, Store.path
    set :session_ttl, Integer(ENV.fetch('SESSION_TTL_SECONDS', '28800'))
    raise ArgumentError, 'SESSION_TTL_SECONDS must be positive' unless session_ttl.positive?
    set :allowed_origins, ENV.fetch('ALLOWED_ORIGINS', 'http://localhost:3000').split(',').map(&:strip)
    set :host_authorization, permitted_hosts: ENV.fetch('ALLOWED_HOSTS', 'localhost,127.0.0.1,::1').split(',').map(&:strip)
    set :login_limiter, LoginLimiter.new
    set :registration_limiter, LoginLimiter.new(limit: 200)
    set :allow_registration, ENV.fetch('ALLOW_REGISTRATION', 'true') == 'true'
    set :dummy_hash, Security.password_hash(SecureRandom.hex(24))
    set :show_exceptions, false
    set :dump_errors, false
    set :logging, false
    set :static, false
    # No cookie authentication. Explicit origin allowlist below handles browser requests.
    set :protection, except: :http_origin

    helpers do
      def store
        @store ||= Store.new(settings.db_path)
      end

      def fail_json(code, message)
        halt code, JSON.generate(errors: [message])
      end

      def body_json
        fail_json(415, 'Expected application/json') unless request.media_type == 'application/json'
        raw = request.body.read(1_048_577)
        fail_json(413, 'Request body exceeds 1 MiB') if raw.bytesize > 1_048_576
        parsed = JSON.parse(raw, max_nesting: 30)
        fail_json(400, 'Expected a JSON object') unless parsed.is_a?(Hash)
        parsed
      rescue JSON::ParserError, EncodingError
        fail_json(400, 'Invalid JSON')
      end

      def authenticated_user
        return @user if @user
        token = request.env['HTTP_AUTHORIZATION'].to_s[/\ABearer ([a-f0-9]{64})\z/, 1]
        fail_json(401, 'Authentication required') unless token
        @token_hash = Security.token_hash(token)
        @user = store.db.get_first_row(<<~SQL, [@token_hash, Time.now.to_i])
          SELECT users.* FROM sessions JOIN users ON users.id = sessions.user_id
          WHERE sessions.token_hash = ? AND sessions.expires_at > ? AND users.active = 1
        SQL
        fail_json(401, 'Session expired or invalid') unless @user
        @user
      end

      def account_json(user)
        { id: user['id'], username: user['username'], avatar: user['avatar'],
          created_at: user['created_at'], last_login: user['last_login'] }
      end
    end

    before do
      content_type :json
      headers 'Cache-Control' => 'no-store', 'X-Content-Type-Options' => 'nosniff', 'Vary' => 'Origin'
      origin = request.env['HTTP_ORIGIN']
      if origin
        fail_json(403, 'Origin not allowed') unless settings.allowed_origins.include?(origin)
        headers 'Access-Control-Allow-Origin' => origin,
                'Access-Control-Allow-Methods' => 'GET, POST, PUT, OPTIONS',
                'Access-Control-Allow-Headers' => 'Content-Type, Authorization'
      end
      # Refuse credentials in URL parameters; no query string is needed by this API.
      fail_json(400, 'Query parameters are not supported') unless request.query_string.empty?
      fail_json(413, 'Request body exceeds 1 MiB') if request.content_length.to_i > 1_048_576
    end

    after do
      @store&.close
    end

    options '*' do
      status 204
      body ''
    end

    get('/health') { JSON.generate(status: 'ok') }
    get '/v1/features' do
      ids = ENV.fetch('COURSE_CHAPTER_IDS', '1,2,3,8,9,10').split(',').map { |id| Integer(id) }
      JSON.generate(ids.map { |id| { feature_name: "chapter_#{id}_enabled", feature_value: 1 } })
    end

    post '/v1/auth/login' do
      data = body_json
      begin
        key = Security.login_key(data['private_key'])
      rescue ArgumentError
        fail_json(400, 'Invalid login key')
      end
      # Limit all key attempts by IP as well as repeated attempts with the same key.
      lookup = Security.key_lookup(key)
      allowed = settings.login_limiter.allow?([request.env['REMOTE_ADDR'], lookup])
      allowed &&= settings.registration_limiter.allow?(['login', request.env['REMOTE_ADDR']])
      unless allowed
        headers 'Retry-After' => '300'
        fail_json(429, 'Too many login attempts; retry in five minutes')
      end
      user = store.user_by_key(lookup)
      verified = Security.valid_password?(user ? user['password_hash'] : settings.dummy_hash, key)
      fail_json(401, 'Invalid login key') unless verified && user && user['active'] == 1
      token = SecureRandom.hex(32)
      # Recheck the hash/status under the write lock, in case an admin reset it during bcrypt verification.
      store.transaction do
        current = store.user_by_key(lookup)
        fail_json(401, 'Invalid login key') unless current && current['active'] == 1 &&
                                                                         current['password_hash'] == user['password_hash']
        store.db.execute('DELETE FROM sessions WHERE expires_at <= ?', [Time.now.to_i])
        store.db.execute('INSERT INTO sessions(token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
                         [Security.token_hash(token), user['id'], Store.now, Time.now.to_i + settings.session_ttl])
        store.db.execute('UPDATE users SET last_login = ? WHERE id = ?', [Store.now, user['id']])
      end
      JSON.generate(token: token)
    end

    # Compatible with the original registration dialog. CLI accounts have meaningful usernames.
    post '/v1/auth/register' do
      fail_json(403, 'Registration is disabled') unless settings.allow_registration
      unless settings.registration_limiter.allow?(['register', request.env['REMOTE_ADDR']])
        headers 'Retry-After' => '300'
        fail_json(429, 'Too many registrations; retry in five minutes')
      end
      data = body_json
      begin
        key = Security.login_key(data['private_key'])
      rescue ArgumentError
        fail_json(422, 'Invalid login key')
      end
      avatar = data.fetch('avatar', '/assets/avatars/1.png')
      fail_json(422, 'Invalid avatar') unless avatar.is_a?(String) && avatar.match?(/\A\/assets\/avatars\/[1-5]\.png\z/)
      progress = data['progress_state']
      fail_json(422, 'Invalid CourseProgress structure') if !progress.nil? && !Progress.valid?(progress)
      lookup = Security.key_lookup(key)
      hash = Security.password_hash(key)
      name = "self-#{SecureRandom.hex(8)}"
      begin
        store.transaction do
          store.create_user(name, hash, key_lookup: lookup, avatar: avatar)
          if progress
            store.db.execute('UPDATE progress SET progress_json = ?, updated_at = ? WHERE user_id = ?',
                             [JSON.generate(progress), Store.now, store.user(name)['id']])
          end
        end
      rescue SQLite3::ConstraintException
        fail_json(409, 'Account already exists')
      end
      status 201
      JSON.generate(account_json(store.user(name)))
    end

    get '/v1/auth/session' do
      JSON.generate(account_json(authenticated_user))
    end

    # The original API also exposes account details by ID. Only the signed-in
    # account is visible here; administrative listing stays in the CLI.
    get '/v1/accounts/:account_id' do
      user = authenticated_user
      id = params['account_id']
      fail_json(400, 'Invalid account ID') unless id.match?(/\A[1-9][0-9]*\z/)
      fail_json(403, 'Account does not match the session') unless id.to_i == user['id']
      JSON.generate(account_json(user))
    end

    post '/v1/auth/logout' do
      authenticated_user
      store.db.execute('DELETE FROM sessions WHERE token_hash = ?', [@token_hash])
      JSON.generate(ok: true)
    end

    get '/v1/progress' do
      user = authenticated_user
      row = store.db.get_first_row('SELECT progress_json, updated_at FROM progress WHERE user_id = ?', [user['id']])
      JSON.generate(progress_state: row['progress_json'] && JSON.parse(row['progress_json']), updated_at: row['updated_at'])
    end

    put '/v1/progress' do
      user = authenticated_user
      data = body_json
      fail_json(422, 'Only progress_state is accepted') unless data.keys == ['progress_state']
      progress = data['progress_state']
      fail_json(422, 'Invalid CourseProgress structure') unless Progress.valid?(progress)
      store.db.execute('UPDATE progress SET progress_json = ?, updated_at = ? WHERE user_id = ?',
                       [JSON.generate(progress), Store.now, user['id']])
      JSON.generate(ok: true)
    end

    # Existing lessons reuse submitted answers/code. They are inert progress data, never executed here.
    get '/v1/data/:lesson_id' do
      user = authenticated_user
      row = store.db.get_first_row('SELECT lesson_data_json FROM progress WHERE user_id = ?', [user['id']])
      data = JSON.parse(row['lesson_data_json'])[params['lesson_id']]
      fail_json(404, 'No saved data for this lesson') unless data
      JSON.generate(data: data)
    end

    put '/v1/data' do
      user = authenticated_user
      input = body_json
      fail_json(422, 'Only lesson_id, data and account_id are accepted') unless
        (input.keys - %w[data lesson_id account_id]).empty? && %w[data lesson_id].all? { |key| input.key?(key) }
      if input.key?('account_id') && input['account_id'] != user['id']
        fail_json(403, 'Account does not match the session')
      end
      lesson = input['lesson_id']
      data = input['data']
      fail_json(422, 'Invalid lesson ID') unless lesson.is_a?(String) && lesson.match?(/\A[A-Za-z0-9_-]{1,100}\z/)
      fail_json(422, 'Invalid lesson data') unless data.is_a?(Hash) && (data.keys - %w[answer code]).empty? &&
                                                   (!data.key?('code') || data['code'].is_a?(String))
      store.transaction do
        row = store.db.get_first_row('SELECT lesson_data_json FROM progress WHERE user_id = ?', [user['id']])
        saved = JSON.parse(row['lesson_data_json'])
        saved[lesson] = data
        encoded = JSON.generate(saved)
        fail_json(413, 'Saved lesson data exceeds 5 MiB per account') if encoded.bytesize > 5_242_880
        store.db.execute('UPDATE progress SET lesson_data_json = ?, updated_at = ? WHERE user_id = ?',
                         [encoded, Store.now, user['id']])
      end
      JSON.generate(ok: true)
    end

    not_found { JSON.generate(errors: ['Endpoint not found']) }
    error SQLite3::BusyException do
      status 503
      headers 'Retry-After' => '1'
      JSON.generate(errors: ['Database busy; please retry'])
    end
    error do
      # Do not log request bodies, authorization headers or exception values.
      warn "Backend error: #{env['sinatra.error'].class}"
      status 500
      JSON.generate(errors: ['Internal server error'])
    end
  end
end
