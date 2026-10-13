import { get } from 'utils'
import { Account } from 'types'
import { SAVING_SATOSHI_PRIVATE_KEY } from 'config/keys'

export default async function getSession(): Promise<Account> {
  const account = await get({ url: '/v1/auth/session', includeToken: true })
  return {
    ...account,
    private_key:
      window.sessionStorage.getItem(SAVING_SATOSHI_PRIVATE_KEY) || '',
  }
}
