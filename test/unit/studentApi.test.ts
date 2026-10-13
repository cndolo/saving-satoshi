import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SAVING_SATOSHI_TOKEN, SAVING_SATOSHI_PRIVATE_KEY } from 'config/keys'
import { get, post, ApiError } from 'utils/fetch'
import login from 'api/auth/login'
import register from 'api/auth/register'
import { getProgressLocal } from 'api/local'
import getSession from 'api/auth/getSession'
import setProgress from 'api/progress/setProgress'
import { defaultProgressState } from 'state/progress/defaultProgress'

// Avoid importing the UI through the project's broad utils barrel.
vi.mock('utils', async () => {
  const client = await import('utils/fetch')
  return { ...client, url: (path: string) => `http://localhost:8000${path}` }
})

vi.mock('api/local', () => ({ getProgressLocal: vi.fn() }))

let saved = new Map<string, string>()
beforeEach(() => {
  saved = new Map()
  vi.stubGlobal('window', {
    sessionStorage: {
      getItem: (key: string) => saved.get(key) || null,
      setItem: (key: string, value: string) => saved.set(key, value),
    },
  })
})
afterEach(() => vi.unstubAllGlobals())
const response = (status: number, json: any) => ({
  ok: status < 400,
  status,
  json: async () => json,
})

describe('student HTTP client', () => {
  it('rejects HTTP errors even when an errors field is missing', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response(401, {})))
    await expect(
      get({ url: '/v1/progress', includeToken: true })
    ).rejects.toBeInstanceOf(ApiError)
  })

  it('uses the tab token and preserves the original login payload', async () => {
    saved.set(SAVING_SATOSHI_TOKEN, 'tab-token')
    const fetch = vi.fn().mockResolvedValue(response(200, {}))
    vi.stubGlobal('fetch', fetch)
    await get({ url: '/v1/progress', includeToken: true })
    expect(fetch.mock.calls[0][1].headers.Authorization).toBe(
      'Bearer tab-token'
    )
    await post({
      url: '/v1/auth/login',
      body: { private_key: 'original-key' },
    })
    expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({
      private_key: 'original-key',
    })
    expect(fetch.mock.calls[1][1].headers.Authorization).toBeUndefined()
  })

  it('keeps the original account dialog compatible without receiving a key from the server', async () => {
    const key = 'a'.repeat(64)
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(response(200, { token: 'new-token' }))
      .mockResolvedValueOnce(response(200, { id: 1, username: 'student' }))
    vi.stubGlobal('fetch', fetch)
    await login(key)
    expect(saved.get(SAVING_SATOSHI_TOKEN)).toBe('new-token')
    expect(saved.get(SAVING_SATOSHI_PRIVATE_KEY)).toBe(key)
    const session = await getSession()
    expect(session.private_key).toBe(key)
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
      private_key: key,
    })
    expect(fetch.mock.calls[1][1].headers.Authorization).toBe(
      'Bearer new-token'
    )
  })

  it('only transfers guest progress when creating a new account', async () => {
    vi.mocked(getProgressLocal).mockResolvedValue(defaultProgressState)
    const fetch = vi.fn().mockResolvedValue(response(201, { id: 1 }))
    vi.stubGlobal('fetch', fetch)
    await register('a'.repeat(64), '/assets/avatars/1.png')
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
      private_key: 'a'.repeat(64),
      avatar: '/assets/avatars/1.png',
      progress_state: defaultProgressState,
    })
  })

  it('serializes progress snapshots', async () => {
    saved.set(SAVING_SATOSHI_TOKEN, 'account-a')
    let complete: (value: any) => void
    const fetch = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            complete = resolve
          })
      )
      .mockResolvedValue(response(200, {}))
    vi.stubGlobal('fetch', fetch)
    const first = setProgress({ ...defaultProgressState, currentChapter: 1 })
    const second = setProgress({ ...defaultProgressState, currentChapter: 2 })
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    complete!(response(200, {}))
    await Promise.all([first, second])
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(
      JSON.parse(fetch.mock.calls[1][1].body).progress_state.currentChapter
    ).toBe(2)
  })

  it('discards queued writes after switching to another token', async () => {
    saved.set(SAVING_SATOSHI_TOKEN, 'account-a')
    let complete: (value: any) => void
    const fetch = vi.fn().mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          complete = resolve
        })
    )
    vi.stubGlobal('fetch', fetch)
    const first = setProgress(defaultProgressState)
    const second = setProgress(defaultProgressState)
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    saved.set(SAVING_SATOSHI_TOKEN, 'account-b')
    complete!(response(200, {}))
    await Promise.all([first, second])
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(fetch.mock.calls[0][1].headers.Authorization).toBe(
      'Bearer account-a'
    )
  })
})
