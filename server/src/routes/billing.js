const express = require('express');
const stripe = require('../stripeClient');
const { requireAuth } = require('../middleware/auth');
const { getStripeCustomerIdForUser } = require('../customerLookup');

const router = express.Router();

// サブスクリプション開始（Billing）用の Checkout Session
// body: { price: 'price_xxx', customerEmail?: string }
router.post('/checkout-session', async (req, res) => {
  try {
    const price = req.body.price || process.env.STRIPE_PRICE_ID_SUBSCRIPTION;
    if (!price) {
      return res.status(400).json({ error: 'price is required' });
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      line_items: [{ price, quantity: 1 }],
      // payment_method_types はあえて指定しない
      customer_email: req.body.customerEmail,
      success_url: `${process.env.CLIENT_URL}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${process.env.CLIENT_URL}/cancel`,
    });

    res.json({ url: session.url, id: session.id });
  } catch (err) {
    console.error('billing checkout session error:', err.message);
    res.status(500).json({ error: 'failed to create subscription checkout session' });
  }
});

// 既存顧客がプラン変更・解約・支払い方法変更を行うための Customer Portal セッション
//
// customerId はリクエストボディから受け取らない。クライアント入力の customerId を
// そのまま信用すると、認証さえ突破すれば任意の他人の顧客IDを渡して
// その人のBilling Portal（請求書・支払い方法・サブスク管理）を開けてしまう（IDOR）。
// 認証済みユーザー自身の Stripe customerId をサーバー側で解決すること。
router.post('/portal-session', requireAuth, async (req, res) => {
  try {
    // TODO: 認証実装後、req.user.id から自社DB経由で Stripe customerId を解決する
    const customerId = await getStripeCustomerIdForUser(req.user.id);

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: process.env.CLIENT_URL,
    });

    res.json({ url: session.url });
  } catch (err) {
    console.error('portal session error:', err.message);
    res.status(500).json({ error: 'failed to create portal session' });
  }
});

module.exports = router;
