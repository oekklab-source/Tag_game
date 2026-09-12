const express = require('express');
const stripe = require('../stripeClient');

const router = express.Router();

// Stripe の署名検証には生ボディが必要なため express.raw() を使う
router.post('/', express.raw({ type: 'application/json' }), (req, res) => {
  let event;
  try {
    event = stripe.webhooks.constructEvent(
      req.body,
      req.headers['stripe-signature'],
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('webhook signature verification failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  switch (event.type) {
    case 'checkout.session.completed':
    case 'checkout.session.async_payment_succeeded': {
      const session = event.data.object;
      if (session.payment_status !== 'unpaid') {
        // TODO: 注文の確定・アクセス権の付与などのフルフィルメント処理をここに実装する
        console.log(`fulfilling checkout session ${session.id}`);
      }
      break;
    }
    case 'checkout.session.async_payment_failed': {
      const session = event.data.object;
      console.log(`payment failed for session ${session.id}`);
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const subscription = event.data.object;
      // TODO: ユーザーのプラン状態をDBに反映する
      console.log(`subscription ${subscription.id} status=${subscription.status}`);
      break;
    }
    case 'invoice.paid': {
      const invoice = event.data.object;
      console.log(`invoice ${invoice.id} paid`);
      break;
    }
    case 'invoice.payment_failed': {
      const invoice = event.data.object;
      console.log(`invoice ${invoice.id} payment failed`);
      break;
    }
    default:
      break;
  }

  res.json({ received: true });
});

module.exports = router;
