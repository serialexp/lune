// Doc 79: a test names the requirement criteria it proves as `[REQ-n.m]` tags
// in its name, as the Zig tests do (tests/test_runner.zig). gothab.io reads
// the keys from a testcase's `requirements` property, and Vitest's JUnit
// reporter writes one property per annotation, named by the annotation's type.
// So each tag becomes an annotation of type `requirements`. Every token between
// `[REQ-` and `]` is passed on as written, like the Zig runner does, so a
// malformed key reaches `gt requirement verify` and is reported there.
//
// Each package's Vitest setup file registers it: `beforeEach(citeRequirements)`.
// No import of vitest here: this file sits outside every package, so it could
// not resolve one.

interface CitingContext {
  task: { name: string };
  annotate(message: string, type?: string): Promise<unknown>;
}

export async function citeRequirements(ctx: CitingContext): Promise<void> {
  for (const m of ctx.task.name.matchAll(/\[(REQ-[^\]]*)\]/g)) {
    await ctx.annotate(m[1], "requirements");
  }
}
