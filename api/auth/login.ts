import { SAVING_SATOSHI_TOKEN, SAVING_SATOSHI_PRIVATE_KEY } from 'config/keys'
import { post } from 'utils'

export default async function login(privateKey: string) {
  const { token } = await post({
    url: '/v1/auth/login',
    body: { private_key: privateKey },
  })
  window.sessionStorage.setItem(SAVING_SATOSHI_TOKEN, token)
  // The original account dialog displays the key. Keep it only in this tab;
  // the backend never stores or returns plaintext login credentials.
  window.sessionStorage.setItem(SAVING_SATOSHI_PRIVATE_KEY, privateKey)
  return true
}
