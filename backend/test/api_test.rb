# frozen_string_literal: true
ENV['APP_ENV'] = 'test'
require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require_relative '../app'
require_relative '../lib/admin'

class ApiTest < Minitest::Test
  include Rack::Test::Methods
  def app = CourseBackend::App

  def setup
    @dir = Dir.mktmpdir('course-backend-test')
    @path = File.join(@dir, 'test.sqlite3')
    CourseBackend::Store.prepare(@path)
    app.set :db_path, @path
    app.set :host_authorization, permitted_hosts: ['example.org']
    app.set :login_limiter, CourseBackend::LoginLimiter.new
    app.set :session_ttl, 28_800
    @store = CourseBackend::Store.new(@path)
    @password = SecureRandom.hex(32)
    @bob_password = SecureRandom.hex(32)
    app.set :allow_registration, true
    app.set :registration_limiter, CourseBackend::LoginLimiter.new(limit: 200)
    # Fast fixture hashing only. Production and CLI always use cost 12.
    hash = BCrypt::Password.create(@password, cost: 4).to_s
    @store.transaction do
      @store.create_user('alice', hash, key_lookup: CourseBackend::Security.key_lookup(@password))
      @store.create_user('bob', BCrypt::Password.create(@bob_password, cost: 4).to_s, key_lookup: CourseBackend::Security.key_lookup(@bob_password))
    end
    header 'Content-Type', 'application/json'
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@dir)
  end

  def json = JSON.parse(last_response.body)
  def login_as(name = 'alice', password = nil)
    password ||= name.downcase == 'bob' ? @bob_password : @password
    header 'Authorization', nil
    post '/v1/auth/login', JSON.generate(private_key: password)
    assert_equal 200, last_response.status, last_response.body
    token = json.fetch('token')
    header 'Authorization', "Bearer #{token}"
    token
  end

  def progress(completed = true)
    { 'currentChapter' => 1, 'currentLesson' => 'CH1INT1', 'chapters' => [
      { 'id' => 1, 'hasDifficulty' => false, 'completed' => false, 'lessons' => [
        { 'id' => 'CH1INT1', 'path' => '/chapter-1/intro-1', 'completed' => completed }
      ] }
    ] }
  end

  def test_login_issues_random_token_stores_only_hash_and_updates_last_login
    token = login_as('ALICE')
    assert_match(/\A[0-9a-f]{64}\z/, token)
    row = @store.db.get_first_row('SELECT * FROM sessions')
    assert_equal CourseBackend::Security.token_hash(token), row['token_hash']
    refute_equal token, row['token_hash']
    refute_nil @store.user('alice')['last_login']
    get '/v1/auth/session'
    assert_equal 'alice', json['username']
    refute json.key?('password_hash')
    refute json.key?('private_key')
    assert_equal 'no-store', last_response.headers['cache-control']
  end

  def test_unknown_key_and_inactive_user_return_same_error
    %w[alice missing].each do |name|
      post '/v1/auth/login', JSON.generate(private_key: SecureRandom.hex(32))
      assert_equal 401, last_response.status
      assert_equal ['Invalid login key'], json['errors']
    end
    @store.db.execute("UPDATE users SET active = 0 WHERE username = 'alice'")
    post '/v1/auth/login', JSON.generate(private_key: @password)
    assert_equal 401, last_response.status
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM sessions')
  end

  def test_all_private_routes_require_authentication
    ['/v1/auth/session', '/v1/accounts/1', '/v1/progress', '/v1/data/CH1INT1'].each do |path|
      get path
      assert_equal 401, last_response.status
    end
    ['/v1/progress', '/v1/data'].each do |path|
      put path, '{}'
      assert_equal 401, last_response.status
    end
    header 'Authorization', 'Bearer invalid'
    get '/v1/progress'
    assert_equal 401, last_response.status
  end

  def test_progress_round_trip_and_account_isolation
    login_as
    get '/v1/progress'
    assert_nil json['progress_state']
    put '/v1/progress', JSON.generate(progress_state: progress)
    assert_equal 200, last_response.status
    get '/v1/progress'
    assert_equal progress, json['progress_state']
    refute_nil json['updated_at']
    login_as('bob')
    get '/v1/progress'
    assert_nil json['progress_state']
    put '/v1/progress', JSON.generate(progress_state: progress(false))
    assert_equal 200, last_response.status
    login_as
    get '/v1/progress'
    assert_equal true, json['progress_state']['chapters'][0]['lessons'][0]['completed']
  end

  def test_client_cannot_choose_another_account
    login_as
    own_id = @store.user('alice')['id']
    other_id = @store.user('bob')['id']
    get "/v1/accounts/#{own_id}"
    assert_equal 200, last_response.status
    assert_equal own_id, json['id']
    assert_equal 'alice', json['username']
    refute json.key?('private_key')
    refute json.key?('password_hash')
    get "/v1/accounts/#{other_id}"
    assert_equal 403, last_response.status
    get '/v1/accounts/not-a-number'
    assert_equal 400, last_response.status
    put '/v1/progress', JSON.generate(progress_state: progress, account_id: @store.user('bob')['id'])
    assert_equal 422, last_response.status
    put '/v1/data', JSON.generate(lesson_id: 'CH1INT1', data: {}, account_id: @store.user('bob')['id'])
    assert_equal 403, last_response.status
    put '/v1/data', JSON.generate(lesson_id: 'CH1INT1', data: {}, account_id: @store.user('alice')['id'])
    assert_equal 200, last_response.status
    get '/v1/progress?account_id=2'
    assert_equal 400, last_response.status
    get '/v1/progress/2'
    assert_equal 404, last_response.status
  end

  def test_saved_code_is_inert_and_account_scoped
    login_as
    data = { 'answer' => ['answer'], 'code' => 'cHJpbnQoMSk=' }
    put '/v1/data', JSON.generate(lesson_id: 'CH1INT1', data: data)
    assert_equal 200, last_response.status
    get '/v1/data/CH1INT1'
    assert_equal data, json['data']
    login_as('bob')
    get '/v1/data/CH1INT1'
    assert_equal 404, last_response.status
    put '/v1/data', JSON.generate(lesson_id: "' OR 1=1", data: data)
    assert_equal 422, last_response.status
  end

  def test_logout_revokes_only_the_current_session
    old = login_as
    current = login_as
    post '/v1/auth/logout', '{}'
    assert_equal 200, last_response.status
    get '/v1/auth/session'
    assert_equal 401, last_response.status
    header 'Authorization', "Bearer #{old}"
    get '/v1/auth/session'
    assert_equal 200, last_response.status
    refute_equal old, current
  end

  def test_expired_sessions_are_rejected
    login_as
    @store.db.execute('UPDATE sessions SET expires_at = ?', [Time.now.to_i - 1])
    get '/v1/progress'
    assert_equal 401, last_response.status
  end

  def test_reset_deactivate_and_delete_revoke_sessions
    admin = CourseBackend::Admin.new(@store)
    login_as
    replacement = SecureRandom.hex(32)
    admin.reset_password('alice', replacement)
    get '/v1/progress'
    assert_equal 401, last_response.status
    @password = replacement
    login_as
    admin.set_active('alice', false)
    get '/v1/progress'
    assert_equal 401, last_response.status
    admin.set_active('alice', true)
    login_as
    admin.delete('alice')
    get '/v1/progress'
    assert_equal 401, last_response.status
    assert_equal 1, @store.db.get_first_value('SELECT COUNT(*) FROM progress')
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM sessions')
  end

  def test_invalid_json_content_type_and_progress
    login_as
    put '/v1/progress', '{bad'
    assert_equal 400, last_response.status
    header 'Content-Type', 'text/plain'
    put '/v1/progress', '{}'
    assert_equal 415, last_response.status
    header 'Content-Type', 'application/json'
    [nil, {}, { 'currentChapter' => '1' }, progress.merge('chapters' => [nil]),
     progress.merge('chapters' => [{ 'id' => 1, 'completed' => false, 'hasDifficulty' => true, 'difficulties' => [nil] }])].each do |value|
      put '/v1/progress', JSON.generate(progress_state: value)
      assert_equal 422, last_response.status
    end
    put '/v1/progress', JSON.generate(progress_state: progress(false))
    assert_equal 200, last_response.status
  end

  def test_payload_limit
    login_as
    put '/v1/progress', 'x' * 1_048_577
    assert_equal 413, last_response.status
  end

  def test_cors_allows_only_configured_origin
    header 'Origin', 'http://localhost:3000'
    options '/v1/progress'
    assert_equal 204, last_response.status
    assert_equal 'http://localhost:3000', last_response.headers['access-control-allow-origin']
    header 'Origin', 'https://untrusted.example'
    post '/v1/auth/login', JSON.generate(private_key: @password)
    assert_equal 403, last_response.status
    refute last_response.headers.key?('access-control-allow-origin')
  end

  def test_login_throttle
    app.set :login_limiter, CourseBackend::LoginLimiter.new(limit: 2)
    2.times do
      post '/v1/auth/login', JSON.generate(private_key: @bob_password)
      assert_equal 200, last_response.status
    end
    post '/v1/auth/login', JSON.generate(private_key: @bob_password)
    assert_equal 429, last_response.status
    assert_equal '300', last_response.headers['retry-after']
  end

  def test_no_admin_or_runner_endpoints
    %w[/v1/admin /repl /runner].each do |path|
      post path, '{}'
      assert_equal 404, last_response.status
    end
    get '/v1/features'
    assert_equal %w[chapter_1_enabled chapter_2_enabled chapter_3_enabled chapter_8_enabled chapter_9_enabled chapter_10_enabled], json.map { |feature| feature['feature_name'] }
  end

  def test_original_frontend_registration_login_and_avatar
    key = SecureRandom.hex(32)
    post '/v1/auth/register', JSON.generate(progress_state: progress, private_key: key.upcase, avatar: '/assets/avatars/4.png')
    assert_equal 201, last_response.status, last_response.body
    assert_match(/\Aself-[0-9a-f]{16}\z/, json['username'])
    refute json.key?('private_key')
    row = @store.user_by_key(CourseBackend::Security.key_lookup(key))
    assert_equal 12, BCrypt::Password.new(row['password_hash']).cost
    refute_includes JSON.generate(row), key
    post '/v1/auth/login', JSON.generate(private_key: key.upcase)
    assert_equal 200, last_response.status
    header 'Authorization', "Bearer #{json['token']}"
    get '/v1/auth/session'
    assert_equal '/assets/avatars/4.png', json['avatar']
    refute json.key?('private_key')
    get '/v1/progress'
    assert_equal progress, json['progress_state']
    post '/v1/auth/register', JSON.generate(private_key: key)
    assert_equal 409, last_response.status
    assert_equal 3, @store.db.get_first_value('SELECT COUNT(*) FROM users')
  end

  def test_registration_can_be_disabled_without_frontend_changes
    app.set :allow_registration, false
    post '/v1/auth/register', JSON.generate(private_key: SecureRandom.hex(32))
    assert_equal 403, last_response.status
    assert_equal 2, @store.db.get_first_value('SELECT COUNT(*) FROM users')
  end

  def test_registration_validates_key_avatar_and_throttles
    post '/v1/auth/register', JSON.generate(private_key: 'invalid')
    assert_equal 422, last_response.status
    post '/v1/auth/register', JSON.generate(private_key: SecureRandom.hex(32), avatar: 'https://untrusted.example/image')
    assert_equal 422, last_response.status
    [{}, false].each do |invalid_progress|
      post '/v1/auth/register', JSON.generate(private_key: SecureRandom.hex(32), progress_state: invalid_progress)
      assert_equal 422, last_response.status
    end
    app.set :registration_limiter, CourseBackend::LoginLimiter.new(limit: 1)
    post '/v1/auth/register', JSON.generate(private_key: SecureRandom.hex(32))
    assert_equal 201, last_response.status
    post '/v1/auth/register', JSON.generate(private_key: SecureRandom.hex(32))
    assert_equal 429, last_response.status
  end

  def test_invalid_login_keys_and_sql_injection_are_rejected
    ["alice' OR 1=1--", '0' * 64, 'f' * 64, 'short', nil].each do |value|
      post '/v1/auth/login', JSON.generate(private_key: value)
      assert_equal 400, last_response.status
    end
    assert_equal 2, @store.db.get_first_value('SELECT COUNT(*) FROM users')
  end
end
