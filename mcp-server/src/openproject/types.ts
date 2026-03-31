export interface WorkPackage {
  id: number;
  subject: string;
  lockVersion: number;
  description: { raw: string } | null;
  _links?: {
    type?: { title: string; href: string };
    priority?: { title: string; href: string };
    status?: { title: string; href: string };
    category?: { title: string; href: string };
    parent?: { href: string };
    assignee?: { title: string; href: string };
    children?: Array<{ href: string }>;
  };
}

export interface WPSummary {
  id: number;
  subject: string;
  type: string;
  priority: string;
  status: string;
  assignee: string | null;
  category: string | null;
  description?: string | null;
}

export interface Relation {
  id: number;
  type: string;
  from: { id: string; subject: string };
  to: { id: string; subject: string };
}

export interface Activity {
  id: number;
  comment: string;
  author: string;
  createdAt: string;
}

export interface WPContext {
  parents: WorkPackage[];
  siblings: WPSummary[];
  children: WPSummary[];
  relations: Relation[];
  comments: Activity[];
}

export interface QualityGate {
  pass: boolean;
  hardBlock: boolean;
  warnings: Array<{ check: string; condition: string; question: string }>;
}
