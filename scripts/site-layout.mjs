import { fileURLToPath } from 'node:url';

const repository = new URL('../', import.meta.url);

// Static Pages source. Local preview and the site bundle must copy this tree.
export const sitePublicURL = new URL('site/public/', repository);
export const siteWorkerURL = new URL('site/worker.js', repository);
export const sitePublicRoot = fileURLToPath(sitePublicURL);
