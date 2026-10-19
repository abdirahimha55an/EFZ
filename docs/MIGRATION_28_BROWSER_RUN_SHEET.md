# Migration 28 - browser run sheet (Staging preview)

The synthetic data below already exists on EFZ-Staging (`adjjamiqwboawqedaapi`). Open the **Preview** of the latest commit on `android/customer-accounts` (GitHub commit status > Vercel > Visit; previews are behind Vercel login), sign in as the Staging **Manager** (`efz.manager@example.com`, the password you set) and open **Admin > Orders & Requests > Website Requests** (customer-app requests are under **Customer App Requests**).
Find each request by the REQ reference below, press **Convert**. Everything is named `TEST-28 B ...`.

Customers: `cust-t28b-a` A (Nexus agreed 10.00) | `cust-t28b-b` B (Fire Ball: Red design 9.50, product-wide 11.00) | `cust-t28b-c` C (list prices) | `cust-t28b-d` D (Nexus agreement pending review).
Pick a customer in the dialog with the search box ("TEST-28 B ...") or the "Customers with this phone" list.

| # | Request (open it) | Do | Expect |
|---|---|---|---|
| S1 list price | `REQ-0097FFA2` (Website) | customer **C**, leave the price | badge "List price", 12; button "Create order"; after Create, order line 12.00 |
| S2a product agreement | `REQ-82F9E457` (Website) | customer **A**, leave the price | badge "Agreed price", 10; order line 10.00 |
| S2b design agreement | `REQ-FF7FCF3B` (Customer App) | customer **B** | chip "Design: E2E Red Design", "Agreed price" 9.5; order line 9.50 with design name |
| S3 failed lookup | `REQ-98ADA0D6` (Website) | DevTools > Network request blocking > add `*resolve_order_price*`; reload, open Convert, pick **C** | red "We could not check this customer's price for this product. Nothing was assumed - press Retry.", empty disabled price, Create disabled. Remove the block, press **Retry**: "List price" 12, Create enabled; convert |
| S4 review blocking | `REQ-DA6F6F41` (Website) | customer **D** | red "...needs to be confirmed first (an agreement is waiting to be verified)", price disabled, Create disabled (no Retry) |
| S5 override | `REQ-9AEDB010` (Website) | customer **A**, type **8** | "Price changed (agreed $10.00)"; table Nexus / 3 / $10.00 / $8.00 / -$6.00 (-$2.00 each); button "Create order with price override" disabled; "too short" stays disabled; a 10+ character reason enables it; convert. "Use the agreed price" undoes the change |
| S6 several designs | `REQ-BD142551` (Customer App) | customer **B** | two lines, chips Red and Blue; prices 9 and 11; Create enabled; order has two lines with their design names |
| S7 customer switch | `REQ-30B6AF30` (Website) | customer **A**, type 8 (override box appears), then search and pick **C** | price box resets to 12, "List price", no override box. **Close without converting** |
| S8 duplicate | `REQ-3DB80B8A` (Website) | convert for **C**; then open the same request in a second tab/reload and try Convert | the converted request offers no Convert; the second tab gets "already converted to order ..." |

Spare: `REQ-F008A581`. Full ids are in the run report. Each conversion creates a pending order (S1, S2a, S2b, S3, S5, S6, S8 = 7 orders at most); cancel them afterwards through the Hub (Order Tracking > Cancel), never delete. Then archive customers A-D and deactivate the design `TEST-28B Blue` (Inventory > product designs, or ask Claude to do it through the supported workflow).

Checks after each conversion (read-only SQL, or ask Claude): order line price, design name, `order_price_resolutions.source` (`list` / `agreement` / `staff_override`), and for S5 the WARNING log `agreed_price_overridden`.
