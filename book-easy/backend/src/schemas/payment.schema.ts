import { z } from 'zod';

/**
 * Request schema for creating a PaymentIntent.
 *
 * NOTE: The client sends the amount because this sample backend is stateless.
 * In a production deployment you would look the booking up server-side
 * (e.g. in Firestore via firebase-admin) and derive the amount from the
 * stored service price — never trust a client-supplied amount.
 */
export const createPaymentIntentSchema = z.object({
  amount: z.coerce
    .number()
    .int('amount must be a whole number in the smallest currency unit (e.g. cents)')
    .positive('amount must be positive'),
  currency: z
    .string()
    .length(3, 'currency must be a 3-letter ISO code')
    .transform((c) => c.toLowerCase())
    .pipe(z.enum(['usd', 'eur', 'gbp', 'inr', 'aud', 'cad'])),
  customerId: z.string().min(1).max(120).optional(),
  bookingId: z.string().min(1).max(120).optional(),
});

export type CreatePaymentIntentInput = z.infer<typeof createPaymentIntentSchema>;
