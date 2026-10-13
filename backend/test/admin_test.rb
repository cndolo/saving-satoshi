# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require_relative '../lib/admin'

class AdminTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('course-admin-test')
    @path = File.join(@dir, 'db.sqlite3')
    CourseBackend::Store.prepare(@path)
    @store = CourseBackend::Store.new(@path)
    @admin = CourseBackend::Admin.new(@store)
    @password = SecureRandom.hex(32)
  end
  def teardown
    @store.close
    FileUtils.remove_entry(@dir)
  end

  def test_passwords_are_bcrypt_with_cost_12_and_not_listed
    @admin.create('Student.1', @password)
    user = @store.user('student.1')
    assert_equal 12, BCrypt::Password.new(user['password_hash']).cost
    assert CourseBackend::Security.valid_password?(user['password_hash'], @password)
    refute_equal @password, user['password_hash']
    assert_equal 0o600, File.stat(@path).mode & 0o777
    out = StringIO.new
    @admin.list(out)
    assert_includes out.string, 'student.1'
    refute_includes out.string, @password
    refute_includes out.string, user['password_hash']
  end

  def test_unsafe_short_long_and_nul_passwords_are_rejected
    ['short', SecureRandom.hex(40), "abcdefghijkl\0"].each do |password|
      assert_raises(ArgumentError) { @admin.create('student', password) }
    end
    assert_raises(ArgumentError) { @admin.create('=FORMULA()', @password) }
  end

  def csv_path(rows)
    path = File.join(@dir, 'users.csv')
    CSV.open(path, 'w') do |csv|
      csv << %w[username password]
      rows.each { |row| csv << row }
    end
    path
  end

  def test_csv_import_is_atomic_and_does_not_reset_existing_users
    path = csv_path([['s1', @password], ['s2', SecureRandom.hex(32)]])
    assert_equal 2, @admin.import(path)
    original = @store.user('s1')['password_hash']
    assert_raises(ArgumentError) { @admin.import(csv_path([['s3', SecureRandom.hex(32)], ['S1', SecureRandom.hex(32)]])) }
    assert_nil @store.user('s3')
    assert_equal original, @store.user('s1')['password_hash']
    assert_raises(ArgumentError) { @admin.import(csv_path([['s4', SecureRandom.hex(32)], ['s5', 'short']])) }
    assert_nil @store.user('s4')
    assert_raises(ArgumentError) { @admin.import(csv_path([['s6', SecureRandom.hex(32)], ['S6', SecureRandom.hex(32)]])) }
    assert_nil @store.user('s6')
  end

  def test_csv_requires_distinct_keys_and_normalizes_hex_casing
    assert_raises(ArgumentError) { @admin.import(csv_path([['s1', @password], ['s2', @password.upcase]])) }
    assert_nil @store.user('s1')
    assert_equal 1, @admin.import(csv_path([['s1', @password.upcase]]))
    assert CourseBackend::Security.valid_password?(@store.user('s1')['password_hash'], @password)
    assert_raises(SQLite3::ConstraintException) { @admin.create('s2', @password) }
    assert_nil @store.user('s2')
  end

  def test_csv_accepts_utf8_bom_and_crlf_but_rejects_semicolon_and_extra_columns
    path = File.join(@dir, 'users.csv')
    File.write(path, "\uFEFFusername,password\r\nStudent-1,#{@password}\r\n")
    assert_equal 1, @admin.import(path)
    ['username;password', 'username,password,extra'].each do |header|
      File.write(path, header + "\n")
      assert_raises(ArgumentError) { @admin.import(path) }
    end
    File.write(path, "username,password\ns2,#{SecureRandom.hex(32)},extra\n")
    assert_raises(ArgumentError) { @admin.import(path) }
    assert_nil @store.user('s2')
  end

  def test_additive_schema_migration_preserves_existing_account_and_progress
    @admin.create('alice', @password)
    # Simulate the earlier users table without the two compatibility columns.
    @store.db.execute('DROP INDEX users_key_lookup')
    @store.db.execute('ALTER TABLE users DROP COLUMN key_lookup')
    @store.db.execute('ALTER TABLE users DROP COLUMN avatar')
    CourseBackend::Store.prepare(@path)
    assert_equal 'alice', @store.user('alice')['username']
    assert_nil @store.user('alice')['key_lookup']
    replacement = SecureRandom.hex(32)
    @admin.reset_password('alice', replacement)
    assert_equal 'alice', @store.user_by_key(CourseBackend::Security.key_lookup(replacement))['username']
    assert_equal 1, @store.db.get_first_value('SELECT COUNT(*) FROM progress')
  end

  def test_export_counts_visible_chapters_selected_track_and_escapes_formulas
    @admin.create('alice', @password)
    lessons = ->(id, completed) { [{ 'id' => id, 'completed' => completed }] }
    progress = { 'currentChapter' => 8, 'currentLesson' => '=untrusted', 'chapters' => [
      { 'id' => 1, 'lessons' => lessons.call('CH1INT1', true) },
      { 'id' => 4, 'lessons' => lessons.call('CH4INT1', false) },
      { 'id' => 8, 'hasDifficulty' => true, 'selectedDifficulty' => 'NORMAL', 'difficulties' => [
        { 'level' => 'NORMAL', 'lessons' => lessons.call('CH8INT1', false) },
        { 'level' => 'HARD', 'lessons' => lessons.call('CH8INT1', true) }
      ] }
    ] }
    @store.db.execute('UPDATE progress SET progress_json = ?, updated_at = ?', [JSON.generate(progress), CourseBackend::Store.now])
    output = StringIO.new
    @admin.export(output)
    row = CSV.parse(output.string, headers: true).first
    assert_equal '1', row['completed_lessons']
    assert_equal '2', row['total_lessons']
    assert_equal '50.0', row['progress_percent']
    assert_equal "'=untrusted", row['current_lesson']
    refute_nil row['progress_updated_at']
  end

  def test_export_includes_accounts_without_progress
    @admin.create('alice', @password)
    output = StringIO.new
    @admin.export(output)
    row = CSV.parse(output.string, headers: true).first
    assert_equal 'alice', row['username']
    assert_equal '0', row['completed_lessons']
    assert_nil row['current_lesson']
  end

  def test_transaction_rolls_back_nonlocal_abort
    catch(:halt) do
      @store.transaction do
        @store.create_user('aborted', BCrypt::Password.create(@password, cost: 4).to_s)
        throw :halt
      end
    end
    assert_nil @store.user('aborted')
    assert_equal 0, @store.db.get_first_value('SELECT COUNT(*) FROM progress')
  end

  def test_backup_includes_wal_and_is_readable
    @admin.create('alice', @password)
    destination = File.join(@dir, 'backup.sqlite3')
    @store.backup(destination)
    backup = CourseBackend::Store.new(destination)
    assert_equal 'alice', backup.user('alice')['username']
    assert_equal 'ok', backup.db.get_first_value('PRAGMA integrity_check')
    backup.close
    assert_equal 0o600, File.stat(destination).mode & 0o777
    assert_raises(ArgumentError) { @store.backup(destination) }
  end

  def test_cli_stdin_and_failure_do_not_print_passwords
    original_path = ENV['DATABASE_PATH']
    ENV['DATABASE_PATH'] = @path
    output, errors = StringIO.new, StringIO.new
    result = CourseBackend::CLI.run(['create', 'alice', '--password-stdin'], input: StringIO.new(@password + "\n"), output: output, errors: errors)
    assert_equal 0, result
    refute_includes output.string + errors.string, @password
    result = CourseBackend::CLI.run(['create', 'bob', @password], output: output, errors: errors)
    assert_equal 1, result
    refute_includes output.string + errors.string, @password
  ensure
    ENV['DATABASE_PATH'] = original_path
  end
end
