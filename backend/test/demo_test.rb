# frozen_string_literal: true
ENV['APP_ENV'] = 'test'
require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require 'stringio'
require_relative '../app'
require_relative '../lib/demo'

class DemoTest < Minitest::Test
  include Rack::Test::Methods
  def app = CourseBackend::App

  def setup
    @dir = Dir.mktmpdir('course-demo-test')
    @path = File.join(@dir, 'demo.sqlite3')
    @accounts = CSV.read(File.join(CourseBackend::Demo::FIXTURE_DIRECTORY, 'accounts.csv'), headers: true)
    app.set :db_path, @path
    app.set :host_authorization, permitted_hosts: ['example.org']
    app.set :login_limiter, CourseBackend::LoginLimiter.new
    app.set :registration_limiter, CourseBackend::LoginLimiter.new(limit: 200)
    header 'Content-Type', 'application/json'
  end

  def teardown
    @store&.close
    FileUtils.remove_entry(@dir)
  end

  def create_demo
    CourseBackend::Demo.create(@path)
    @store = CourseBackend::Store.new(@path)
  end

  def key_for(username)
    @accounts.find { |row| row['username'] == username }.fetch('password')
  end

  def json = JSON.parse(last_response.body)

  def login_as(username)
    header 'Authorization', nil
    post '/v1/auth/login', JSON.generate(private_key: key_for(username))
    assert_equal 200, last_response.status
    header 'Authorization', "Bearer #{json.fetch('token')}"
  end

  def test_generator_creates_hashed_accounts_and_meaningful_progress
    create_demo
    assert_equal 4, @store.db.get_first_value('SELECT COUNT(*) FROM users')
    assert_equal 3, @store.db.get_first_value('SELECT COUNT(*) FROM users WHERE active = 1')
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM sessions')
    assert_equal 0o600, File.stat(@path).mode & 0o777
    @accounts.each do |row|
      user = @store.user(row['username'])
      assert_equal 12, BCrypt::Password.new(user['password_hash']).cost
      assert CourseBackend::Security.valid_password?(user['password_hash'], row['password'])
      refute_includes JSON.generate(user), row['password']
    end
    output = StringIO.new
    CourseBackend::Admin.new(@store).export(output)
    rows = CSV.parse(output.string, headers: true).to_h { |row| [row['username'], row] }
    assert_nil rows['demo-new']['current_lesson']
    assert_equal 'CH1INT2', rows['demo-lesson']['current_lesson']
    assert_equal '1', rows['demo-lesson']['completed_lessons']
    assert_equal 'CH2INT1', rows['demo-chapter']['current_lesson']
    assert_equal '11', rows['demo-chapter']['completed_lessons']
    assert_equal '98', rows['demo-chapter']['total_lessons']
    assert_equal '11.2', rows['demo-chapter']['progress_percent']
    assert_equal '0', rows['demo-disabled']['active']
    refute_nil rows['demo-chapter']['last_login']
    refute_nil rows['demo-chapter']['progress_updated_at']
  end

  def test_generator_refuses_existing_files_and_ignores_the_course_database_environment
    original_environment = ENV['DATABASE_PATH']
    production = File.join(@dir, 'course.sqlite3')
    File.write(production, 'existing course data')
    ENV['DATABASE_PATH'] = production
    create_demo
    assert_equal 'existing course data', File.read(production)
    before = File.binread(@path)
    assert_raises(Errno::EEXIST) { CourseBackend::Demo.create(@path) }
    assert_equal before, File.binread(@path)
    link = File.join(@dir, 'linked.sqlite3')
    File.symlink(production, link)
    assert_raises(Errno::EEXIST) { CourseBackend::Demo.create(link) }
    assert_equal 'existing course data', File.read(production)
  ensure
    ENV['DATABASE_PATH'] = original_environment
  end

  def test_csv_import_alone_creates_active_accounts_without_seeded_progress
    CourseBackend::Store.prepare(@path)
    @store = CourseBackend::Store.new(@path)
    admin = CourseBackend::Admin.new(@store)
    assert_equal 4, admin.import(File.join(CourseBackend::Demo::FIXTURE_DIRECTORY, 'accounts.csv'))
    assert_equal 4, @store.db.get_first_value('SELECT COUNT(*) FROM users WHERE active = 1')
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM progress WHERE progress_json IS NOT NULL')
    assert_raises(ArgumentError) { admin.import(File.join(CourseBackend::Demo::FIXTURE_DIRECTORY, 'accounts.csv')) }
    assert_equal 4, @store.db.get_first_value('SELECT COUNT(*) FROM users')
  end

  def test_demo_accounts_support_login_progress_isolation_and_deactivation
    create_demo
    login_as('demo-lesson')
    get '/v1/progress'
    assert_equal 'CH1INT2', json['progress_state']['currentLesson']
    progress = json['progress_state']
    progress['chapters'][0]['lessons'][1]['completed'] = true
    progress['currentLesson'] = 'CH1GEN1'
    put '/v1/progress', JSON.generate(progress_state: progress)
    assert_equal 200, last_response.status
    login_as('demo-new')
    get '/v1/progress'
    assert_nil json['progress_state']
    login_as('demo-lesson')
    get '/v1/progress'
    assert_equal 'CH1GEN1', json['progress_state']['currentLesson']
    header 'Authorization', nil
    post '/v1/auth/login', JSON.generate(private_key: key_for('demo-disabled'))
    assert_equal 401, last_response.status
    admin = CourseBackend::Admin.new(@store)
    admin.set_active('demo-disabled', true)
    login_as('demo-disabled')
    admin.set_active('demo-disabled', false)
    get '/v1/progress'
    assert_equal 401, last_response.status
  end

  def test_prepared_database_and_export_match_the_documented_scenarios
    prepared = File.join(CourseBackend::Demo::FIXTURE_DIRECTORY, 'course-demo.sqlite3')
    @store = CourseBackend::Store.new(prepared)
    assert_equal 'ok', @store.db.get_first_value('PRAGMA integrity_check')
    assert_empty @store.db.execute('PRAGMA foreign_key_check')
    assert_equal 4, @store.db.get_first_value('SELECT COUNT(*) FROM users')
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM sessions')
    @accounts.each do |row|
      assert CourseBackend::Security.valid_password?(@store.user(row['username'])['password_hash'], row['password'])
    end
    output = StringIO.new
    CourseBackend::Admin.new(@store).export(output)
    assert_equal File.read(File.join(CourseBackend::Demo::FIXTURE_DIRECTORY, 'progress-export.csv')), output.string
  end
end
