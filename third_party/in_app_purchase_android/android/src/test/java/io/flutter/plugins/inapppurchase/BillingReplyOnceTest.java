// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.inapppurchase;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ProductDetailsResponseListener;
import com.android.billingclient.api.QueryProductDetailsResult;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import kotlin.Unit;
import org.junit.Before;
import org.junit.Test;
import org.mockito.ArgumentCaptor;

/** Regression coverage for Crashlytics 10820c7c: one Pigeon reply per billing query. */
public class BillingReplyOnceTest {
  private BillingClient billingClient;
  private MethodCallHandlerImpl handler;
  private final List<ResultCompat<PlatformProductDetailsResponse>> replies = new ArrayList<>();

  @Before
  public void setUp() {
    billingClient = mock(BillingClient.class);
    BillingClientFactory factory = mock(BillingClientFactory.class);
    when(factory.createBillingClient(any(), any(), any(), any())).thenReturn(billingClient);
    handler =
        new MethodCallHandlerImpl(
            null, mock(Context.class), mock(InAppPurchaseCallbackApi.class), factory);
    handler.startConnection(
        1L,
        PlatformBillingChoiceMode.PLAY_BILLING_ONLY,
        new PlatformPendingPurchasesParams(false),
        ignored -> Unit.INSTANCE);
  }

  @Test
  public void duplicateProductDetailsResponsesReplyOnlyOncePerQuery() {
    queryProducts();
    ArgumentCaptor<ProductDetailsResponseListener> listener =
        ArgumentCaptor.forClass(ProductDetailsResponseListener.class);
    verify(billingClient).queryProductDetailsAsync(any(), listener.capture());

    respond(listener.getValue(), BillingClient.BillingResponseCode.OK, "first");
    respond(listener.getValue(), BillingClient.BillingResponseCode.ERROR, "duplicate");

    assertFirstReplyOnly();

    // The guard belongs to the request, so a later query must still receive a reply.
    doAnswer(
            invocation -> {
              respond(invocation.getArgument(1), BillingClient.BillingResponseCode.OK, "next");
              return null;
            })
        .when(billingClient)
        .queryProductDetailsAsync(any(), any());
    queryProducts();
    assertEquals(2, replies.size());
    assertEquals("next", replies.get(1).getOrNull().getBillingResult().getDebugMessage());
  }

  @Test
  public void exceptionAfterProductDetailsResponseDoesNotSendAnErrorReply() {
    doAnswer(
            invocation -> {
              respond(invocation.getArgument(1), BillingClient.BillingResponseCode.OK, "first");
              // Both the listener and the synchronous exception path share the same guard.
              throw new IllegalStateException("Billing failed after delivering a response");
            })
        .when(billingClient)
        .queryProductDetailsAsync(any(), any());

    queryProducts();

    assertFirstReplyOnly();
  }

  private void queryProducts() {
    handler.queryProductDetailsAsync(
        Collections.singletonList(new PlatformQueryProduct("pro", PlatformProductType.SUBS)),
        ResultCompat.asCompatCallback(
            result -> {
              replies.add(result);
              return Unit.INSTANCE;
            }));
  }

  private void respond(ProductDetailsResponseListener listener, int code, String message) {
    QueryProductDetailsResult products = mock(QueryProductDetailsResult.class);
    when(products.getProductDetailsList()).thenReturn(Collections.emptyList());
    when(products.getUnfetchedProductList()).thenReturn(Collections.emptyList());
    listener.onProductDetailsResponse(
        BillingResult.newBuilder().setResponseCode(code).setDebugMessage(message).build(), products);
  }

  private void assertFirstReplyOnly() {
    assertEquals(1, replies.size());
    assertNull(replies.get(0).exceptionOrNull());
    assertEquals("first", replies.get(0).getOrNull().getBillingResult().getDebugMessage());
  }
}
