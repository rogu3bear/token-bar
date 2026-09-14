import { publicConfig } from '../../lib/config.mjs';
export const onRequestGet = ({ env }) => publicConfig(env);
