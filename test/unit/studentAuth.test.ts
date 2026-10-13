import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { createStore } from 'jotai'
import { useAuthFunctions } from 'state/AuthFunctions'
import { accountAtom, isAuthLoadingAtom } from 'state/state'
import { loadProgressAtom } from 'state/progress/actions'
import {
  courseProgressAtom,
  isLoadingProgressAtom,
  isProgressLoadedAtom,
} from 'state/progress/atoms'
import { defaultProgressState } from 'state/progress/defaultProgress'
import { getProgressLocal } from 'api/local'
import { getProgress } from 'api/progress'
import { getSession, login, logout } from 'api/auth'
import { SAVING_SATOSHI_TOKEN } from 'config/keys'

let store: ReturnType<typeof createStore>
vi.mock('jotai', async (importOriginal) => {
  const actual = await importOriginal<typeof import('jotai')>()
  return {
    ...actual,
    useSetAtom:
      (atom: any) =>
      (...args: any[]) =>
        store.set(atom, ...args),
  }
})
vi.mock('hooks', () => ({
  useLocalizedRoutes: () => ({ chaptersUrl: '/en/chapters' }),
}))
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock('api/auth', () => ({
  login: vi.fn(),
  getSession: vi.fn(),
  logout: vi.fn(),
}))
vi.mock('api/local', () => ({
  getProgressLocal: vi.fn(),
  setProgressLocal: vi.fn(),
}))
vi.mock('api/progress', () => ({
  getProgress: vi.fn(),
  setProgress: vi.fn().mockResolvedValue(undefined),
}))

const guest = {
  ...defaultProgressState,
  currentChapter: 2,
  currentLesson: 'CH2INT1',
}
const student = { id: 1, private_key: 'a'.repeat(64) }

describe('original authentication transitions', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    store = createStore()
    const storage = new Map<string, string>()
    vi.stubGlobal('window', {
      sessionStorage: {
        getItem: (key: string) => storage.get(key) || null,
        removeItem: (key: string) => storage.delete(key),
      },
      localStorage: { removeItem: vi.fn() },
    })
    vi.mocked(getSession).mockResolvedValue(student)
    vi.mocked(login).mockResolvedValue(true)
    vi.mocked(logout).mockResolvedValue(undefined)
    vi.mocked(getProgressLocal).mockResolvedValue(guest)
    vi.mocked(getProgress).mockResolvedValue(defaultProgressState)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('holds lesson navigation until the original dialog has loaded account progress', async () => {
    const auth = useAuthFunctions()
    expect(await auth.attemptLogin(student.private_key)).toBe(true)
    expect(store.get(isAuthLoadingAtom)).toBe(false)
    expect(store.get(isLoadingProgressAtom)).toBe(true)
    expect(store.get(isProgressLoadedAtom)).toBe(false)
    await store.set(loadProgressAtom)
    expect(store.get(isLoadingProgressAtom)).toBe(false)
    expect(store.get(isProgressLoadedAtom)).toBe(true)
    expect(getProgressLocal).not.toHaveBeenCalled()
  })

  it('restores guest hydration after logout so later guest work can be saved at signup', async () => {
    store.set(accountAtom, student)
    store.set(courseProgressAtom, {
      ...defaultProgressState,
      currentChapter: 10,
    })
    store.set(isProgressLoadedAtom, true)
    await useAuthFunctions().attemptLogout()
    expect(logout).toHaveBeenCalledOnce()
    expect(store.get(accountAtom)).toBeUndefined()
    expect(store.get(courseProgressAtom)).toEqual(guest)
    expect(store.get(isProgressLoadedAtom)).toBe(true)
    expect(store.get(isLoadingProgressAtom)).toBe(false)
    expect(getProgress).not.toHaveBeenCalled()
    expect(window.localStorage.removeItem).toHaveBeenCalledWith(
      SAVING_SATOSHI_TOKEN
    )
  })

  it('allows guest persistence again after a rejected login', async () => {
    vi.mocked(login).mockRejectedValue(new Error('Denied'))
    expect(await useAuthFunctions().attemptLogin(student.private_key)).toBe(
      false
    )
    expect(store.get(accountAtom)).toBeUndefined()
    expect(store.get(courseProgressAtom)).toEqual(guest)
    expect(store.get(isProgressLoadedAtom)).toBe(true)
    expect(store.get(isAuthLoadingAtom)).toBe(false)
  })
})
