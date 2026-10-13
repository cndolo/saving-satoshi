import { SAVING_SATOSHI_TOKEN, SAVING_SATOSHI_PRIVATE_KEY } from 'config/keys'
import { post } from 'utils'

export default async function logout() {
  try {
    await post({ url: '/v1/auth/logout', body: {}, includeToken: true })
  } finally {
    window.sessionStorage.removeItem(SAVING_SATOSHI_TOKEN)
    window.sessionStorage.removeItem(SAVING_SATOSHI_PRIVATE_KEY)
  }
}
