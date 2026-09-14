import { handleFeedback } from "../../lib/feedback.mjs";
export const onRequest = ({ request, env }) => handleFeedback(request, env);
