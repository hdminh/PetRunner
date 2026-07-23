export class APIError extends Error {
  constructor(message: string, readonly status = 0) { super(message); this.name = "APIError"; }
}

export class DashboardAPI {
  private version: "v2" | "v1" = "v2";

  private url(version: "v2" | "v1", path: string, query?: Record<string, string>) {
    const url = new URL(`api/${version}/${path.replace(/^\/+/, "")}`, document.baseURI);
    Object.entries(query ?? {}).forEach(([key, value]) => value && url.searchParams.set(key, value));
    return url;
  }

  /** Same-origin asset/image URL that prefers the negotiated API version. */
  assetURL(path: string, query?: Record<string, string>) {
    return this.url(this.version, path, query).toString();
  }

  async request<T>(path: string, init: RequestInit = {}, query?: Record<string, string>): Promise<T> {
    const versions: ("v2" | "v1")[] = this.version === "v2" ? ["v2", "v1"] : ["v1"];
    let lastError: APIError | undefined;
    for (const version of versions) {
      try {
        const response = await fetch(this.url(version, path, query), {
          cache: "no-store", credentials: "same-origin", headers: { Accept: "application/json", ...(init.body ? { "Content-Type": "application/json" } : {}), ...init.headers }, ...init,
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new APIError(typeof payload.message === "string" ? payload.message : `Request failed (${response.status})`, response.status);
        this.version = version;
        return payload as T;
      } catch (error) {
        lastError = error instanceof APIError ? error : new APIError(error instanceof Error ? error.message : "Dashboard is unavailable");
        if (lastError.status !== 404 || version === versions.at(-1)) throw lastError;
      }
    }
    throw lastError ?? new APIError("Dashboard is unavailable");
  }

  get<T>(path: string, query?: Record<string, string>) { return this.request<T>(path, {}, query); }
  post<T>(path: string, body?: unknown) { return this.request<T>(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) }); }
  put<T>(path: string, body: unknown) { return this.request<T>(path, { method: "PUT", body: JSON.stringify(body) }); }
  delete<T>(path: string) { return this.request<T>(path, { method: "DELETE" }); }
}
