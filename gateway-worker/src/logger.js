/**
 * Structured logger for the gateway worker.
 * Uses winston for JSON output in production, pretty-printed in dev.
 */

import { createLogger as winstonCreateLogger, format, transports } from 'winston';

export function createLogger(level = 'info') {
  const isProd = process.env.NODE_ENV === 'production';

  return winstonCreateLogger({
    level,
    format: isProd
      ? format.combine(format.timestamp(), format.json())
      : format.combine(
          format.colorize(),
          format.timestamp({ format: 'HH:mm:ss' }),
          format.printf(({ level, message, timestamp, ...meta }) => {
            const metaStr = Object.keys(meta).length
              ? '\n  ' + JSON.stringify(meta, null, 2).replace(/\n/g, '\n  ')
              : '';
            return `${timestamp} ${level}: ${message}${metaStr}`;
          })
        ),
    transports: [new transports.Console()],
  });
}