import type { Request, Response } from 'express';
import type { PaymentGateway } from '../services/stripe.service.js';
import type { CreatePaymentIntentInput } from '../schemas/payment.schema.js';
import { ApiError } from '../utils/api-error.js';

/**
 * Thin controller: shape validation already happened in the route middleware,
 * so this enforces the business rule (amount ceiling) and calls the gateway.
 */
export function createPaymentsController(gateway: PaymentGateway, maxAmountCents: number) {
  return {
    async createPaymentIntent(req: Request, res: Response): Promise<void> {
      const input = req.body as CreatePaymentIntentInput;
      if (input.amount > maxAmountCents) {
        throw ApiError.badRequest(
          'amount_too_large',
          `amount must not exceed ${maxAmountCents} minor units`,
        );
      }
      const result = await gateway.createPaymentIntent(input);
      res.status(201).json({
        paymentIntentId: result.id,
        clientSecret: result.clientSecret,
        status: result.status,
      });
    },
  };
}
