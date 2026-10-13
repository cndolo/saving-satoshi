import url from './url'
import { FetchOptions } from 'types'
import { SAVING_SATOSHI_TOKEN } from 'config/keys'

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
    this.name = 'ApiError'
  }
}

async function request(method: string, options: FetchOptions) {
  const headers = {
    'Content-Type': 'application/json',
    ...options.headers,
  }
  if (options.includeToken) {
    const token = window.sessionStorage.getItem(SAVING_SATOSHI_TOKEN)
    if (token) headers['Authorization'] = `Bearer ${token}`
  }
  const res = await fetch(url(options.url), {
    method,
    headers,
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
    cache: 'no-store',
  })
  let json: any
  try {
    json = await res.json()
  } catch {
    throw new ApiError(res.status, 'Invalid response from backend')
  }
  if (!res.ok || json.errors) {
    throw new ApiError(res.status, json.errors?.[0] || 'Backend request failed')
  }
  return json
}

export const get = (options: FetchOptions) => request('GET', options)
export const post = (options: FetchOptions) => request('POST', options)
export const put = (options: FetchOptions) => request('PUT', options)
