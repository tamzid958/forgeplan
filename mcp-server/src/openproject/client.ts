import type {
  WorkPackage,
  WPContext,
  WPSummary,
  QualityGate,
} from "./types.js";

export class OpenProjectClient {
  private baseUrl: string;
  private apiKey: string;

  constructor(baseUrl: string, apiKey: string) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.apiKey = apiKey;
  }

  private get authHeader(): string {
    return `Basic ${Buffer.from(`apikey:${this.apiKey}`).toString("base64")}`;
  }

  private async request<T>(path: string, options?: RequestInit): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const res = await fetch(url, {
      ...options,
      headers: {
        Accept: "application/hal+json",
        "Content-Type": "application/json",
        Authorization: this.authHeader,
        ...options?.headers,
      },
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`OpenProject API ${res.status}: ${body}`);
    }

    return res.json() as Promise<T>;
  }

  async fetchWP(wpId: number): Promise<WorkPackage> {
    return this.request<WorkPackage>(`/api/v3/work_packages/${wpId}`);
  }

  async fetchWPContext(wpId: number): Promise<WPContext> {
    const wp = await this.fetchWP(wpId);

    const parentHref = wp._links?.parent?.href;
    const childrenHrefs =
      wp._links?.children?.map((c: { href: string }) => c.href) ?? [];
    const relationsPath = `/api/v3/work_packages/${wpId}/relations`;
    const activitiesPath = `/api/v3/work_packages/${wpId}/activities`;

    const [relationsRes, activitiesRes] = await Promise.all([
      this.request<{ _embedded: { elements: unknown[] } }>(relationsPath),
      this.request<{ _embedded: { elements: unknown[] } }>(activitiesPath),
    ]);

    // Parent chain (up to 2 levels)
    const parents: WorkPackage[] = [];
    if (parentHref) {
      const parent = await this.request<WorkPackage>(parentHref);
      parents.push(parent);
      if (parent._links?.parent?.href) {
        const grandparent = await this.request<WorkPackage>(
          parent._links.parent.href,
        );
        parents.push(grandparent);
      }
    }

    // Siblings from parent's children
    let siblings: WPSummary[] = [];
    if (parents.length > 0) {
      const parentChildren =
        parents[0]._links?.children?.map((c: { href: string }) => c.href) ??
        [];
      const siblingWPs = await Promise.all(
        parentChildren
          .filter(
            (href: string) => !href.endsWith(`/${wpId}`),
          )
          .map((href: string) => this.request<WorkPackage>(href)),
      );
      siblings = siblingWPs.map((s) => ({
        id: s.id,
        subject: s.subject,
        type: s._links?.type?.title ?? "",
        priority: s._links?.priority?.title ?? "",
        status: s._links?.status?.title ?? "",
        assignee: s._links?.assignee?.title ?? null,
        category: s._links?.category?.title ?? null,
      }));
    }

    // Children
    const childWPs = await Promise.all(
      childrenHrefs.map((href: string) => this.request<WorkPackage>(href)),
    );
    const children: WPSummary[] = childWPs.map((c) => ({
      id: c.id,
      subject: c.subject,
      type: c._links?.type?.title ?? "",
      priority: c._links?.priority?.title ?? "",
      status: c._links?.status?.title ?? "",
      assignee: c._links?.assignee?.title ?? null,
      category: c._links?.category?.title ?? null,
    }));

    // Relations
    const relations = (
      (relationsRes._embedded?.elements ?? []) as Record<string, unknown>[]
    ).map((r) => ({
      id: r.id as number,
      type: r._type as string,
      from: {
        id: ((r._links as Record<string, { href: string }>)?.from?.href ?? "")
          .split("/")
          .pop() as string,
        subject: "",
      },
      to: {
        id: ((r._links as Record<string, { href: string }>)?.to?.href ?? "")
          .split("/")
          .pop() as string,
        subject: "",
      },
    }));

    // Last 5 comments
    const allActivities = (activitiesRes._embedded?.elements ??
      []) as Record<string, unknown>[];
    const comments = allActivities
      .filter(
        (a) =>
          a.comment &&
          (a.comment as Record<string, unknown>).raw &&
          ((a.comment as Record<string, unknown>).raw as string).trim() !== "",
      )
      .slice(-5)
      .map((a) => ({
        id: a.id as number,
        comment: (a.comment as Record<string, string>).raw,
        author:
          ((a._links as Record<string, { title?: string }>)?.user?.title) ??
          "Unknown",
        createdAt: a.createdAt as string,
      }));

    return { parents, siblings, children, relations, comments };
  }

  async updateWPStatus(
    wpId: number,
    statusId: number,
    lockVersion: number,
    assignSelf?: boolean,
  ): Promise<{ lockVersion: number }> {
    const links: Record<string, { href: string }> = {
      status: { href: `/api/v3/statuses/${statusId}` },
    };
    if (assignSelf) {
      links.assignee = { href: "/api/v3/users/me" };
    }

    try {
      const res = await this.request<{ lockVersion: number }>(
        `/api/v3/work_packages/${wpId}`,
        {
          method: "PATCH",
          body: JSON.stringify({ lockVersion, _links: links }),
        },
      );
      return { lockVersion: res.lockVersion };
    } catch (err) {
      if (err instanceof Error && err.message.includes("409")) {
        // Refetch and retry once
        const fresh = await this.fetchWP(wpId);
        const res = await this.request<{ lockVersion: number }>(
          `/api/v3/work_packages/${wpId}`,
          {
            method: "PATCH",
            body: JSON.stringify({
              lockVersion: fresh.lockVersion,
              _links: links,
            }),
          },
        );
        return { lockVersion: res.lockVersion };
      }
      throw err;
    }
  }

  async postComment(wpId: number, markdown: string): Promise<void> {
    await this.request(`/api/v3/work_packages/${wpId}/activities`, {
      method: "POST",
      body: JSON.stringify({ comment: { raw: markdown } }),
    });
  }

  async queryByStatus(
    projectId: string,
    statusId: number,
    assigneeFilter?: string,
  ): Promise<WPSummary[]> {
    const filters: Array<Record<string, unknown>> = [
      { status_id: { operator: "=", values: [String(statusId)] } },
    ];
    if (assigneeFilter) {
      filters.push({
        assignee: { operator: "=", values: [assigneeFilter] },
      });
    }
    const params = new URLSearchParams({
      filters: JSON.stringify(filters),
      sortBy: JSON.stringify([["priority", "asc"]]),
    });

    const res = await this.request<{
      _embedded: { elements: WorkPackage[] };
    }>(`/api/v3/projects/${projectId}/work_packages?${params.toString()}`);

    return (res._embedded?.elements ?? []).map((wp) => ({
      id: wp.id,
      subject: wp.subject,
      type: wp._links?.type?.title ?? "",
      priority: wp._links?.priority?.title ?? "",
      status: wp._links?.status?.title ?? "",
      assignee: wp._links?.assignee?.title ?? null,
      category: wp._links?.category?.title ?? null,
    }));
  }

  async fetchSprintWPs(
    projectId: string,
    sprintName?: string,
  ): Promise<WPSummary[]> {
    const filters: Array<Record<string, unknown>> = [];
    if (sprintName) {
      filters.push({
        version: { operator: "=", values: [sprintName] },
      });
    }
    const params = new URLSearchParams({
      filters: JSON.stringify(filters),
      sortBy: JSON.stringify([["priority", "asc"]]),
    });

    const res = await this.request<{
      _embedded: { elements: WorkPackage[] };
    }>(`/api/v3/projects/${projectId}/work_packages?${params.toString()}`);

    return (res._embedded?.elements ?? []).map((wp) => ({
      id: wp.id,
      subject: wp.subject,
      type: wp._links?.type?.title ?? "",
      priority: wp._links?.priority?.title ?? "",
      status: wp._links?.status?.title ?? "",
      assignee: wp._links?.assignee?.title ?? null,
      category: wp._links?.category?.title ?? null,
    }));
  }
}

const PLACEHOLDER_PATTERNS = [
  /^\s*tbd\s*$/i,
  /^\s*todo\s*$/i,
  /^\s*wip\s*$/i,
  /^\s*description goes here\s*$/i,
  /^\s*fill in later\s*$/i,
  /^\s*\.{2,}\s*$/,
  /^\s*n\/a\s*$/i,
];

export function evaluateQualityGate(
  wp: WorkPackage,
  wpContext: WPContext,
  wpType: string,
): QualityGate {
  const warnings: Array<{ check: string; condition: string; question: string }> =
    [];
  const desc = wp.description?.raw?.trim() ?? "";

  // Hard blocks
  if (!desc) {
    return {
      pass: false,
      hardBlock: true,
      warnings: [
        {
          check: "Empty description",
          condition: "Description is empty",
          question:
            "This work package has no description. Please add one in OpenProject or provide requirements here.",
        },
      ],
    };
  }

  for (const pattern of PLACEHOLDER_PATTERNS) {
    if (pattern.test(desc)) {
      return {
        pass: false,
        hardBlock: true,
        warnings: [
          {
            check: "Placeholder text",
            condition: `Description matches placeholder: "${desc}"`,
            question:
              "The description is a placeholder. Please provide actual requirements.",
          },
        ],
      };
    }
  }

  // Duplicate check
  for (const sibling of wpContext.siblings) {
    if (sibling.id !== wp.id) {
      // Shallow compare — full description would need deep-fetch for non-subtasks
      // This is a best-effort check
    }
  }

  // Type-specific checks
  const type = wpType.toLowerCase();

  if (type === "bug") {
    if (
      !/steps|reproduce|when|then|expected|actual/i.test(desc)
    ) {
      warnings.push({
        check: "Reproduction steps",
        condition: "No reproduction steps found",
        question:
          "How do you reproduce this bug? What is the expected vs actual behavior?",
      });
    }
    if (!/error|exception|stack|trace|log/i.test(desc)) {
      warnings.push({
        check: "Error context",
        condition: "No error messages or stack traces mentioned",
        question:
          "Are there any error messages, stack traces, or log output?",
      });
    }
    if (!/environment|browser|version|platform|os/i.test(desc)) {
      warnings.push({
        check: "Environment",
        condition: "No environment info",
        question:
          "What environment does this occur in? (browser, OS, version, etc.)",
      });
    }
    if (!/file|module|endpoint|service|component|page/i.test(desc)) {
      warnings.push({
        check: "Affected area",
        condition: "Cannot determine affected area",
        question:
          "Which part of the system is affected? (endpoint, page, service, etc.)",
      });
    }
  }

  if (type === "feature") {
    if (!/should|must|can|criteria|accept/i.test(desc) && !/^[\s]*[-*\d]/m.test(desc)) {
      warnings.push({
        check: "Acceptance criteria",
        condition: "No acceptance criteria found",
        question:
          "What are the acceptance criteria? What defines 'done' for this feature?",
      });
    }
    if (/data|field|model|schema|entity/i.test(desc) && !/type|string|int|boolean|number|varchar/i.test(desc)) {
      warnings.push({
        check: "Data model",
        condition: "Implies data but no schema details",
        question:
          "What data does this feature handle? Any specific fields, types, or constraints?",
      });
    }
    if (/endpoint|api|route|request/i.test(desc) && !/get|post|put|patch|delete|\/api/i.test(desc)) {
      warnings.push({
        check: "API contract",
        condition: "Implies endpoint but no method/path",
        question:
          "What should the API look like? (method, path, request/response shape)",
      });
    }
    if (/ui|page|form|modal|button|component/i.test(desc) && !/click|select|input|display|show|navigate/i.test(desc)) {
      warnings.push({
        check: "UI behavior",
        condition: "Implies UI but no interaction flow",
        question:
          "What should the user see and interact with? Any specific UI requirements?",
      });
    }
    if (!/role|permission|auth|access|admin|user/i.test(desc)) {
      warnings.push({
        check: "Auth/permissions",
        condition: "No access control mentioned",
        question:
          "Who can access this? Any role or permission requirements?",
      });
    }
  }

  if (type === "user story") {
    if (!/should|must|can|criteria|accept/i.test(desc) && !/^[\s]*[-*\d]/m.test(desc)) {
      warnings.push({
        check: "Acceptance criteria",
        condition: "No acceptance criteria found",
        question:
          "What are the acceptance criteria? What defines 'done' for this story?",
      });
    }
    if (!/as a|user|persona|role/i.test(desc)) {
      warnings.push({
        check: "User persona",
        condition: "No user role specified",
        question: "Which user role/persona is this for?",
      });
    }
    if (!/flow|step|then|when|scenario/i.test(desc)) {
      warnings.push({
        check: "Happy path",
        condition: "No success scenario",
        question:
          "What does the successful flow look like step by step?",
      });
    }
    if (!/error|empty|limit|invalid|edge|fail/i.test(desc)) {
      warnings.push({
        check: "Edge cases",
        condition: "No error/edge states",
        question:
          "What happens when things go wrong? (invalid input, empty data, limits)",
      });
    }
  }

  if (type === "epic") {
    if (wpContext.children.length === 0 && !/component|sub-feature|module|part/i.test(desc)) {
      warnings.push({
        check: "Scope boundaries",
        condition: "No children and no sub-components outlined",
        question:
          "What are the main components/sub-features this epic covers?",
      });
    }
    if (!/interface|contract|shared|model|schema/i.test(desc)) {
      warnings.push({
        check: "Shared contracts",
        condition: "No shared interfaces mentioned",
        question:
          "What shared interfaces or data models should the scaffolding define?",
      });
    }
    if (!/pattern|architecture|framework|convention/i.test(desc)) {
      warnings.push({
        check: "Tech decisions",
        condition: "No architectural direction",
        question:
          "Any architectural decisions already made? (patterns, libraries, conventions)",
      });
    }
  }

  if (type === "task") {
    if (desc.length < 100) {
      warnings.push({
        check: "Specificity",
        condition: "Description under 100 characters",
        question:
          "Can you provide more detail on what exactly needs to be implemented?",
      });
    }
    if (!/file|endpoint|class|component|function|module/i.test(desc)) {
      warnings.push({
        check: "Expected output",
        condition: "No concrete deliverables mentioned",
        question:
          "What files or components should this produce?",
      });
    }
  }

  if (type === "subtask") {
    if (!/scope|boundary|only|limit|just/i.test(desc)) {
      warnings.push({
        check: "Scope boundary",
        condition: "Cannot determine scope boundary",
        question:
          "What is the exact boundary of this subtask vs its siblings?",
      });
    }
  }

  // General checks (all types)
  if (desc.length > 0 && desc.length < 50) {
    warnings.push({
      check: "Short description",
      condition: "Under 50 characters",
      question:
        "The description is very brief. Can you elaborate on the requirements?",
    });
  }
  if (/maybe|or we could|not sure if|tbd on/i.test(desc)) {
    warnings.push({
      check: "Ambiguous scope",
      condition: "Contains ambiguous language",
      question:
        "There are open questions in the description. Can you clarify the ambiguous parts?",
    });
  }
  if (/external.*api|third.?party|integration.*with/i.test(desc)) {
    warnings.push({
      check: "External dependency",
      condition: "References external service",
      question:
        "This references an external system. What are the integration details? (URL, auth, format)",
    });
  }
  if (/breaking.*change|change.*api|deprecat|migrat/i.test(desc)) {
    warnings.push({
      check: "Breaking change",
      condition: "Implies changing existing interface",
      question:
        "This looks like it changes an existing interface. Should I maintain backwards compatibility?",
    });
  }

  return {
    pass: warnings.length === 0,
    hardBlock: false,
    warnings,
  };
}
