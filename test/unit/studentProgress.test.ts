import { createStore } from 'jotai'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { accountAtom } from 'state/state'
import { loadProgressAtom } from 'state/progress/actions'
import {
  courseProgressAtom,
  isProgressLoadedAtom,
  progressErrorAtom,
  syncedCourseProgressAtom,
} from 'state/progress/atoms'
import { defaultProgressState } from 'state/progress/defaultProgress'
import { getProgress, setProgress } from 'api/progress'
import { getProgressLocal, setProgressLocal } from 'api/local'

vi.mock('api/progress', () => ({
  getProgress: vi.fn(),
  setProgress: vi.fn().mockResolvedValue(undefined),
}))
vi.mock('api/local', () => ({
  getProgressLocal: vi.fn(),
  setProgressLocal: vi.fn(),
}))

const account = (id: number) => ({ id, username: `student${id}` })

describe('student progress isolation', () => {
  beforeEach(() => vi.clearAllMocks())

  it('loads an empty student account from defaults without importing guest progress', async () => {
    const store = createStore()
    store.set(accountAtom, account(1))
    vi.mocked(getProgress).mockResolvedValue(null)
    vi.mocked(getProgressLocal).mockResolvedValue({
      ...defaultProgressState,
      currentChapter: 10,
    })
    await store.set(loadProgressAtom)
    expect(store.get(courseProgressAtom).currentChapter).toBe(1)
    expect(getProgressLocal).not.toHaveBeenCalled()
    expect(store.get(isProgressLoadedAtom)).toBe(true)
  })

  it('keeps writes disabled and reports an error after a failed server load', async () => {
    const store = createStore()
    store.set(accountAtom, account(1))
    vi.mocked(getProgress).mockRejectedValue(new Error('offline'))
    await store.set(loadProgressAtom)
    expect(store.get(isProgressLoadedAtom)).toBe(false)
    expect(store.get(progressErrorAtom)).toContain('could not be loaded')
    expect(getProgressLocal).not.toHaveBeenCalled()
    expect(setProgress).not.toHaveBeenCalled()
  })

  it('ignores an old response after switching accounts', async () => {
    const store = createStore()
    store.set(accountAtom, account(1))
    let resolve: (value: typeof defaultProgressState) => void
    vi.mocked(getProgress).mockImplementation(
      () =>
        new Promise((done) => {
          resolve = done
        })
    )
    const loading = store.set(loadProgressAtom)
    store.set(accountAtom, account(2))
    resolve!({ ...defaultProgressState, currentChapter: 10 })
    await loading
    expect(store.get(courseProgressAtom).currentChapter).toBe(1)
    expect(store.get(isProgressLoadedAtom)).toBe(false)
  })

  it('only writes authenticated progress to the backend', async () => {
    const store = createStore()
    store.set(accountAtom, account(1))
    store.set(isProgressLoadedAtom, true)
    const unsubscribe = store.sub(syncedCourseProgressAtom, () => {})
    await vi.waitFor(() => expect(setProgress).toHaveBeenCalled())
    expect(setProgressLocal).not.toHaveBeenCalled()
    unsubscribe()
  })

  it('keeps guest progress in local storage', async () => {
    const store = createStore()
    vi.mocked(getProgressLocal).mockResolvedValue({
      ...defaultProgressState,
      currentChapter: 2,
    })
    await store.set(loadProgressAtom)
    expect(store.get(courseProgressAtom).currentChapter).toBe(2)
    expect(getProgress).not.toHaveBeenCalled()
  })
})
