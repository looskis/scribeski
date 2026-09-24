// Submit guard. Scribeski never submits a form; the worker does. Every click the bundle
// makes goes through guardedClick, and there is no other path to .click().

export class SubmitGuardError extends Error {
  constructor(what: string) {
    super(`submit_guard: refused to click ${what}`);
  }
}

/** True for anything whose activation could submit a form or leave the page. */
export function isForbidden(el: Element): boolean {
  const tag = el.tagName.toLowerCase();
  if (tag === "button") {
    // A <button> with no type attribute inside a form is a submit button.
    const type = (el.getAttribute("type") ?? "").toLowerCase();
    if (type === "submit" || (type === "" && (el as HTMLButtonElement).form)) return true;
  }
  if (tag === "input") {
    const type = (el as HTMLInputElement).type.toLowerCase();
    if (type === "submit" || type === "image") return true;
  }
  if (tag === "a" && (el as HTMLAnchorElement).href) return true;
  if (el.closest(".form-actions, [role=toolbar][data-form-actions]")) return true;
  return false;
}

export function guardedClick(el: Element): void {
  if (isForbidden(el)) throw new SubmitGuardError(describe(el));
  (el as HTMLElement).click();
}

function describe(el: Element): string {
  const id = el.id ? `#${el.id}` : "";
  return `<${el.tagName.toLowerCase()}${id}>`;
}
