//
//  PluginProductInfoBuilder.swift
//  LunaPluginIngest
//

import Foundation
import LunaHTMLClassification
import LunaModels

/// Builds the pipeline's `ProductInfo` from a plugin's `product` Model.
///
/// `ProductInfo` lives in LunaHTMLClassification, above LunaModels, so
/// `ProductModelAdopting` answers with the Model plus a resolved image and this
/// tier assembles the value (`PluginModelAdopting`'s `.product` case).
public enum PluginProductInfoBuilder {

    public static func make(from model: ProductModel, imageURL: URL?) -> ProductInfo {
        let identifiers = ProductIdentifiers(
            gtin: model.identifiers?.gtin,
            mpn: model.identifiers?.mpn,
            sku: model.identifiers?.sku,
            brand: model.identifiers?.brand ?? model.brand)
        return ProductInfo(
            name: model.name,
            priceAmount: model.price.amount,
            priceCurrency: model.price.currency.uppercased(),
            imageURL: imageURL ?? model.imageURL,
            brand: model.brand,
            productID: model.productID,
            identifiers: identifiers,
            sellers: sellers(of: model))
    }

    /// A seller with no price of its own cannot be tracked, so it is dropped
    /// rather than carried at the page's own price — a store row's price is what
    /// the alert threshold and the graph read.
    private static func sellers(of model: ProductModel) -> [ProductSellerInfo] {
        model.sellers.compactMap { seller in
            guard let price = seller.price else { return nil }
            return ProductSellerInfo(
                url: seller.url,
                price: ProductPrice(
                    amount: price.amount, currency: price.currency.uppercased()))
        }
    }
}
