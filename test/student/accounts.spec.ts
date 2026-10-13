import { expect, test, Page } from '@playwright/test'
import { execFileSync } from 'child_process'
import { randomBytes } from 'crypto'
import { resolve, join } from 'path'
import { defaultProgressState } from '../../state/progress/defaultProgress'

const api = 'http://localhost:8001'
function createAccount() {
  const username = `student-${randomBytes(8).toString('hex')}`
  const password = randomBytes(32).toString('hex')
  execFileSync(
    'bundle',
    ['exec', 'ruby', 'bin/admin', 'create', username, '--password-stdin'],
    {
      cwd: resolve('backend'),
      env: {
        ...process.env,
        DATABASE_PATH: join(process.env.STUDENT_TEST_DIR!, 'course.sqlite3'),
      },
      input: password + '\n',
      stdio: ['pipe', 'pipe', 'pipe'],
    }
  )
  return { username, password }
}

async function signIn(
  page: Page,
  credentials: { username: string; password: string }
) {
  await page.getByRole('button', { name: 'profile', exact: true }).click()
  await page
    .getByPlaceholder('Enter your private key')
    .fill(credentials.password)
  await page.getByRole('button', { name: 'Sign in', exact: true }).click()
  await expect(
    page.getByRole('heading', { name: 'Welcome back!', exact: true })
  ).toBeVisible()
}

async function tabToken(page: Page) {
  return page.evaluate(() => sessionStorage.getItem('saving-satoshi-token'))
}

test('original login rejects bad credentials and retains registration', async ({
  page,
}) => {
  const credentials = createAccount()
  await page.goto('/en/chapters')
  await page.getByRole('button', { name: 'profile', exact: true }).click()
  await page
    .getByPlaceholder('Enter your private key')
    .fill(randomBytes(32).toString('hex'))
  const denied = page.waitForResponse((res) =>
    res.url().endsWith('/v1/auth/login')
  )
  await page.getByRole('button', { name: 'Sign in', exact: true }).click()
  expect((await denied).status()).toBe(401)
  expect(await tabToken(page)).toBeNull()
  await expect(
    page.getByText("Don't have an account?", { exact: true })
  ).toBeVisible()
})

test('student accounts remain isolated on the same browser and survive reload', async ({
  page,
  request,
}) => {
  const alice = createAccount()
  const bob = createAccount()
  const login = await request.post(`${api}/v1/auth/login`, {
    data: { private_key: alice.password },
  })
  const { token } = await login.json()
  const progress = structuredClone(defaultProgressState)
  progress.currentChapter = 2
  progress.currentLesson = 'CH2INT1'
  progress.chapters[0].completed = true
  if (!progress.chapters[0].hasDifficulty)
    progress.chapters[0].lessons.forEach((lesson) => {
      lesson.completed = true
    })
  const saved = await request.put(`${api}/v1/progress`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { progress_state: progress },
  })
  expect(saved.status()).toBe(200)
  await page.goto('/en/chapters')
  await page.evaluate(() =>
    localStorage.setItem(
      'SavingSatoshiProgress',
      JSON.stringify({ currentChapter: 10, chapters: [] })
    )
  )
  await signIn(page, alice)
  expect(
    await page.evaluate(() => localStorage.getItem('saving-satoshi-token'))
  ).toBeNull()
  await page
    .getByRole('button', { name: 'Take me to where I left off', exact: true })
    .click()
  await expect(page).toHaveURL(/chapter-2\/intro-1/)
  await page.reload()
  await page.getByRole('button', { name: 'profile', exact: true }).click()
  await expect(
    page.getByRole('heading', { name: 'You are logged in', exact: true })
  ).toBeVisible()
  const oldToken = await tabToken(page)
  await page.getByRole('button', { name: 'Sign out', exact: true }).click()
  expect(await tabToken(page)).toBeNull()
  const revoked = await request.get(`${api}/v1/progress`, {
    headers: { Authorization: `Bearer ${oldToken}` },
  })
  expect(revoked.status()).toBe(401)
  await signIn(page, bob)
  await page
    .getByRole('button', { name: 'Take me to where I left off', exact: true })
    .click()
  await expect(page).toHaveURL(/chapter-1\/intro-1/)
  const bobToken = await tabToken(page)
  const state = await request.get(`${api}/v1/progress`, {
    headers: { Authorization: `Bearer ${bobToken}` },
  })
  expect((await state.json()).progress_state.currentChapter).toBe(1)
  const preserved = await request.get(`${api}/v1/progress`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  expect((await preserved.json()).progress_state.currentChapter).toBe(2)
})

test('failed progress load shows retry and never overwrites server state', async ({
  page,
}) => {
  const account = createAccount()
  let writes = 0
  await page.route(`${api}/v1/progress`, async (route) => {
    if (route.request().method() === 'GET') {
      await route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ errors: ['Unavailable'] }),
      })
    } else {
      writes++
      await route.continue()
    }
  })
  await page.goto('/en/chapters')
  await signIn(page, account)
  await expect(page.getByRole('alert')).toContainText(
    'Progress could not be loaded'
  )
  expect(writes).toBe(0)
  await page.unroute(`${api}/v1/progress`)
  await page.getByRole('button', { name: 'Retry', exact: true }).click()
  await expect(page.getByRole('alert')).toHaveCount(0)
})

test('original signup preserves the guest lesson progress', async ({
  page,
  request,
}) => {
  await page.goto('/en/chapters/chapter-1/intro-1')
  await page.getByRole('button', { name: 'Continue', exact: true }).click()
  await expect(page).toHaveURL(/chapter-1\/intro-2/)
  await page.getByRole('button', { name: 'profile', exact: true }).click()
  await page
    .getByRole('button', { name: "Don't have an account?", exact: true })
    .click()
  await page.locator('label.switch .slider').click()
  await page.getByRole('button', { name: 'Done', exact: true }).click()
  await expect(
    page.getByRole('heading', { name: 'Save your progress', exact: true })
  ).toHaveCount(0)
  await expect(page).toHaveURL(/chapter-1\/intro-2/)
  const token = await tabToken(page)
  expect(token).toBeTruthy()
  const response = await request.get(`${api}/v1/progress`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  expect((await response.json()).progress_state.currentLesson).toBe('CH1INT2')
})
