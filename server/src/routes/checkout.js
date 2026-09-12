const express = require('express');
const stripe = require('../stripeClient');

const router = express.Router();

// 単発決済（Payments）用の Checkout Session を作成する
// body: { items: [{ price: 'price_xxx', quantity: 1 }] }
router.post('/session', async (req, res) => {
  try {
    const { items } = req.body;
    if (!Array.isArray(items) || items.length === 0) {
      return res.status(400).json({ error: 'items is required' });
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: items.map((item) => ({
        price: item.price,
        quantity: item.quantity ?? 1,
      })),
      // payment_method_types はあえて指定しない（動的決済手段を使う）
      success_url: `${process.env.CLIENT_URL}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${process.env.CLIENT_URL}/cancel`,
    });

    res.json({ url: session.url, id: session.id });
  } catch (err) {
    console.error('checkout session error:', err.message);
    res.status(500).json({ error: 'failed to create checkout session' });
  }
});

module.exports = router;
