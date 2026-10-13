# frozen_string_literal: true
require_relative 'app'
CourseBackend::Store.prepare
run CourseBackend::App
