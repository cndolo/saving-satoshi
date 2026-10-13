import { defineConfig } from '@playwright/test'
import { mkdtempSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

// Worker processes inherit this path. Never reuse DATABASE_PATH from a real deployment.
const directory =
  process.env.STUDENT_TEST_DIR ||
  mkdtempSync(join(tmpdir(), 'saving-satoshi-browser-'))
process.env.STUDENT_TEST_DIR = directory
const database = join(directory, 'course.sqlite3')

export default defineConfig({
  testDir: './test/student',
  workers: 1,
  retries: 0,
  timeout: 60000,
  globalTeardown: './test/student/cleanup.ts',
  use: {
    baseURL: 'http://localhost:3001',
    headless: true,
    channel: process.env.PLAYWRIGHT_CHANNEL,
  },
  webServer: [
    {
      command: 'bundle exec puma -C puma.rb config.ru',
      cwd: './backend',
      url: 'http://localhost:8001/health',
      env: {
        DATABASE_PATH: database,
        BIND: 'tcp://127.0.0.1:8001',
        ALLOWED_ORIGINS: 'http://localhost:3001',
        ALLOWED_HOSTS: 'localhost,127.0.0.1',
      },
      reuseExistingServer: false,
    },
    {
      command: 'yarn build && yarn start -p 3001',
      url: 'http://localhost:3001',
      timeout: 120000,
      env: { NEXT_PUBLIC_API_ENDPOINT: 'http://localhost:8001' },
      reuseExistingServer: false,
    },
  ],
})
