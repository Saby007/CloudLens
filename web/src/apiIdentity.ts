import { BrowserCacheLocation, InteractionRequiredAuthError, PublicClientApplication, type AccountInfo } from '@azure/msal-browser';

export const IDENTITY_REQUIRED_EVENT = 'mkai-identity-required';
type IdentityConfiguration = { tenantId: string; apiClientId: string; webClientId: string; scope: string };
type IdentityClient = { client: PublicClientApplication; configuration: IdentityConfiguration };
// Dev-only operator mode: the API acts as one configured operator, so the browser signs nobody in.
type OperatorSession = { operatorMode: true; tenantId: string };
export type VerifiedIdentity = { userId: string; userDetails: string; tenantId: string; features?: { aiNarration: boolean }; operatorMode?: boolean };
let clientPromise: Promise<IdentityClient | OperatorSession> | null = null;
let profileInitialization: { hint: string; promise: Promise<VerifiedIdentity> } | null = null;
let pendingChallenge: { accountId: string; claims?: string } | null = null;

export class ApiIdentityRequiredError extends Error {
  constructor() {
    super('Connect your Microsoft account to verify access.');
    this.name = 'ApiIdentityRequiredError';
  }
}

async function identitySession(): Promise<IdentityClient | OperatorSession> {
  if (!clientPromise) {
    clientPromise = (async () => {
      const response = await fetch('/api/auth/config', { credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error('API identity configuration is unavailable. Contact the operator.');
      const configuration: IdentityConfiguration & { mode?: unknown } = await response.json();
      const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;
      const configuredId = (value: unknown) => typeof value === 'string' && uuid.test(value) && value !== '00000000-0000-0000-0000-000000000000';
      if (configuration.mode === 'operator') {
        if (!configuredId(configuration.tenantId)) throw new Error('API identity configuration is invalid. Contact the operator.');
        const operator: OperatorSession = { operatorMode: true, tenantId: configuration.tenantId };
        return operator;
      }
      if (![configuration.tenantId, configuration.apiClientId, configuration.webClientId].every(configuredId)
        || configuration.scope !== `api://${configuration.apiClientId}/access_as_user`) {
        throw new Error('API identity configuration is invalid. Contact the operator.');
      }
      const client = new PublicClientApplication({
        auth: {
          clientId: configuration.webClientId,
          authority: `https://login.microsoftonline.com/${configuration.tenantId}`,
          redirectUri: `${window.location.origin}/auth-callback.html`,
          navigateToLoginRequestUrl: false,
          clientCapabilities: ['CP1'],
        },
        cache: { cacheLocation: BrowserCacheLocation.SessionStorage },
        system: { iframeHashTimeout: 8000, windowHashTimeout: 90000, loggerOptions: { piiLoggingEnabled: false, loggerCallback: () => undefined } },
      });
      await client.initialize();
      return { client, configuration };
    })().catch((error) => { clientPromise = null; throw error; });
  }
  return clientPromise;
}

function isOperatorSession(session: IdentityClient | OperatorSession): session is OperatorSession {
  return 'operatorMode' in session;
}

function chooseAccount(client: PublicClientApplication, configuration: IdentityConfiguration): AccountInfo | null {
  const active = client.getActiveAccount();
  if (active) return active.tenantId.toLowerCase() === configuration.tenantId.toLowerCase() ? active : null;
  const accounts = client.getAllAccounts().filter((account) => account.tenantId.toLowerCase() === configuration.tenantId.toLowerCase());
  return accounts.length === 1 ? accounts[0] : null;
}

function identityRequired(): never {
  window.dispatchEvent(new Event(IDENTITY_REQUIRED_EVENT));
  throw new ApiIdentityRequiredError();
}

function challengeClaims(response: Response): string | undefined {
  const header = response.headers.get('www-authenticate') ?? '';
  if (header.length > 8192 || !/^Bearer\s/i.test(header) || !/\berror="insufficient_claims"/i.test(header)) return undefined;
  const matches = [...header.matchAll(/(?:^|,)\s*claims="([A-Za-z0-9+/=]+)"/gi)];
  if (matches.length !== 1) return undefined;
  try {
    const decoded = new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(matches[0][1]), (character) => character.charCodeAt(0)));
    if (decoded.length > 4096) return undefined;
    const payload = JSON.parse(decoded);
    if (!payload || typeof payload !== 'object' || !payload.access_token || typeof payload.access_token !== 'object' || Array.isArray(payload.access_token)) return undefined;
    return JSON.stringify(payload);
  } catch { return undefined; }
}

function checkedAccount(account: AccountInfo | null, configuration: IdentityConfiguration): AccountInfo {
  if (!account || account.tenantId.toLowerCase() !== configuration.tenantId.toLowerCase()) throw new ApiIdentityRequiredError();
  if (pendingChallenge && pendingChallenge.accountId !== account.homeAccountId) pendingChallenge = null;
  return account;
}

function interactiveClaims(client: PublicClientApplication, configuration: IdentityConfiguration): { claims?: string } {
  const account = chooseAccount(client, configuration);
  return account && pendingChallenge?.accountId === account.homeAccountId && pendingChallenge.claims
    ? { claims: pendingChallenge.claims } : {};
}

function operatorFetch(path: string, init?: RequestInit): Promise<Response> {
  // Operator mode has no token to attach, and no identity header a caller set may reach the API.
  const headers = new Headers(init?.headers);
  for (const name of ['authorization', 'x-meghkosha-user-token', 'x-ms-client-principal']) headers.delete(name);
  return fetch(path, { ...init, headers, credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
}

export async function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  const target = new URL(path, window.location.origin);
  if (target.origin !== window.location.origin || !target.pathname.startsWith('/api/') || target.username || target.password) {
    throw new Error('Identity tokens can only be sent to this application API.');
  }
  if (init?.signal?.aborted) throw new DOMException('Request aborted', 'AbortError');
  const session = await identitySession();
  if (isOperatorSession(session)) return operatorFetch(path, init);
  const { client, configuration } = session;
  const account = chooseAccount(client, configuration);
  if (!account) return identityRequired();
  let token: string;
  try {
    const challenge = pendingChallenge?.accountId === account.homeAccountId ? pendingChallenge : null;
    const result = await client.acquireTokenSilent({ account, scopes: [configuration.scope],
      ...(challenge ? { forceRefresh: true, ...(challenge.claims ? { claims: challenge.claims } : {}) } : {}),
    });
    if (!result.account || result.account.homeAccountId !== account.homeAccountId
      || result.account.tenantId.toLowerCase() !== configuration.tenantId.toLowerCase()) return identityRequired();
    token = result.accessToken;
    if (!token) return identityRequired();
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError || error instanceof ApiIdentityRequiredError) return identityRequired();
    throw new Error('Microsoft identity verification is temporarily unavailable. Retry or reconnect your account.');
  }
  if (init?.signal?.aborted) throw new DOMException('Request aborted', 'AbortError');
  if (chooseAccount(client, configuration)?.homeAccountId !== account.homeAccountId) return identityRequired();
  const headers = new Headers(init?.headers);
  headers.delete('x-meghkosha-user-token');
  headers.delete('x-ms-client-principal');
  headers.set('Authorization', `Bearer ${token}`);
  const response = await fetch(path, { ...init, headers, credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
  if (chooseAccount(client, configuration)?.homeAccountId !== account.homeAccountId) return identityRequired();
  if (response.status === 401) {
    pendingChallenge = { accountId: account.homeAccountId, claims: challengeClaims(response) };
    window.dispatchEvent(new Event(IDENTITY_REQUIRED_EVENT));
  } else if (response.ok && pendingChallenge?.accountId === account.homeAccountId) {
    pendingChallenge = null;
  }
  return response;
}

async function verifiedProfile(): Promise<VerifiedIdentity> {
  const response = await apiFetch('/api/auth/me', { cache: 'no-store', signal: AbortSignal.timeout(5000) });
  if (response.status === 401) return identityRequired();
  if (!response.ok) throw new Error('Your identity could not be verified by the API. Reconnect or contact the operator.');
  const profile: VerifiedIdentity = await response.json();
  const session = await identitySession();
  const tenantId = isOperatorSession(session) ? session.tenantId : session.configuration.tenantId;
  if (typeof profile.userId !== 'string' || !profile.userId || typeof profile.userDetails !== 'string' || !profile.userDetails
    || typeof profile.tenantId !== 'string' || profile.tenantId.toLowerCase() !== tenantId.toLowerCase()) throw new Error('The API returned an invalid identity profile.');
  return isOperatorSession(session) ? { ...profile, operatorMode: true } : profile;
}

async function resolveApiIdentity(loginHint: string): Promise<VerifiedIdentity> {
  const session = await identitySession();
  if (isOperatorSession(session)) return verifiedProfile();
  const { client, configuration } = session;
  let account = chooseAccount(client, configuration);
  if (!account) {
    if (!loginHint.trim()) throw new ApiIdentityRequiredError();
    try {
      account = (await client.ssoSilent({ scopes: [configuration.scope], loginHint })).account;
    } catch {
      throw new ApiIdentityRequiredError();
    }
  }
  client.setActiveAccount(checkedAccount(account, configuration));
  return verifiedProfile();
}

export function initializeApiIdentity(loginHint: string): Promise<VerifiedIdentity> {
  const hint = loginHint.trim().toLowerCase();
  if (profileInitialization?.hint === hint) return profileInitialization.promise;
  const promise = resolveApiIdentity(loginHint).finally(() => {
    if (profileInitialization?.promise === promise) profileInitialization = null;
  });
  profileInitialization = { hint, promise };
  return promise;
}

export async function connectApiIdentity(loginHint: string): Promise<VerifiedIdentity> {
  const session = await identitySession();
  if (isOperatorSession(session)) return verifiedProfile();
  const { client, configuration } = session;
  const result = await client.loginPopup({ scopes: [configuration.scope], loginHint, prompt: 'select_account',
    ...interactiveClaims(client, configuration) });
  client.setActiveAccount(checkedAccount(result.account, configuration));
  return verifiedProfile();
}

export async function redirectApiIdentity(loginHint: string): Promise<void> {
  const session = await identitySession();
  // Nothing to sign in to: reloading reads the operator identity from the API again.
  if (isOperatorSession(session)) {
    window.location.replace('/');
    return;
  }
  const { client, configuration } = session;
  await client.loginRedirect({ scopes: [configuration.scope], loginHint: loginHint || undefined, prompt: 'select_account',
    ...interactiveClaims(client, configuration) });
}

export async function completeIdentityRedirect(): Promise<void> {
  const session = await identitySession();
  if (!isOperatorSession(session)) {
    const result = await session.client.handleRedirectPromise();
    session.client.setActiveAccount(checkedAccount(result?.account ?? null, session.configuration));
  }
  window.location.replace('/');
}

export async function signOutApiIdentity(): Promise<void> {
  const session = await identitySession();
  if (isOperatorSession(session)) {
    profileInitialization = null;
    return;
  }
  const { client, configuration } = session;
  const account = chooseAccount(client, configuration);
  pendingChallenge = null;
  profileInitialization = null;
  await client.clearCache();
  await client.logoutRedirect({ account, postLogoutRedirectUri: window.location.origin });
}