import { Router, type NextFunction, type Request, type RequestHandler, type Response } from 'express';
import rateLimit from 'express-rate-limit';
import { validateBody } from '../middleware/validate.js';
import { createPaymentIntentSchema } from '../schemas/payment.schema.js';
import { createPaymentsController } from '../controllers/payments.controller.js';
import type { PaymentGateway } from '../services/stripe.service.js';

// Async handlers reject with promises; wrap so errors always reach the
// central error handler instead of crashing the process.
const asyncHandler =
  (fn: (req: Request, res: Response) => Promise<void>): RequestHandler =>
  (req, res, next: NextFunction) => {
    fn(req, res).catch(next);
  };

export function createPaymentsRouter(gateway: PaymentGateway, maxAmountCents: number): Router {
  const controller = createPaymentsController(gateway, maxAmountCents);
  const router = Router();

  // Payments are a sensitive endpoint — throttle per IP to limit abuse.
  const paymentLimiter = rateLimit({
    windowMs: 60_000,
    limit: 20,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: { code: 'rate_limited', message: 'Too many requests, slow down.' } },
  });

  router.post(
    '/payment-intent',
    paymentLimiter,
    validateBody(createPaymentIntentSchema),
    asyncHandler((req, res) => controller.createPaymentIntent(req, res)),
  );

  return router;
}
