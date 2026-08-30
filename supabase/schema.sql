-- EFZ Elite Football Zone - Supabase Schema
-- Run this in the Supabase SQL Editor

-- 1. Create Enums
CREATE TYPE order_status AS ENUM ('pending', 'paid', 'delivered', 'cancelled');
CREATE TYPE product_category AS ENUM ('Football', 'Futsal', 'Accessories');

-- 2. Create Products Table
CREATE TABLE public.products (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    size TEXT NOT NULL,
    durability TEXT,
    surface_type TEXT,
    is_wholesale BOOLEAN DEFAULT true,
    price NUMERIC(10, 2) NOT NULL,
    stock INTEGER NOT NULL DEFAULT 0,
    image_url TEXT,
    category product_category NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 3. Create Orders Table
CREATE TABLE public.orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_number TEXT UNIQUE NOT NULL, -- e.g., ORD-1001
    customer_name TEXT NOT NULL,
    phone_number TEXT NOT NULL,
    arena_name TEXT,
    product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    total_price NUMERIC(10, 2) NOT NULL,
    delivery_location TEXT NOT NULL,
    notes TEXT,
    status order_status DEFAULT 'pending'::order_status NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 4. Set up Row Level Security (RLS)
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

-- Product Policies:
-- Anyone can view products
CREATE POLICY "Products are viewable by everyone." 
ON public.products FOR SELECT 
USING (true);

-- Only authenticated admins can insert/update/delete products
CREATE POLICY "Products are editable by authenticated users only." 
ON public.products FOR ALL 
USING (auth.role() = 'authenticated');

-- Order Policies:
-- Anyone can insert an order (public order form)
CREATE POLICY "Anyone can insert orders." 
ON public.orders FOR INSERT 
WITH CHECK (true);

-- Only authenticated admins can view and update orders
CREATE POLICY "Orders are viewable and editable by authenticated users only." 
ON public.orders FOR SELECT 
USING (auth.role() = 'authenticated');

CREATE POLICY "Orders can be updated by authenticated users only." 
ON public.orders FOR UPDATE
USING (auth.role() = 'authenticated');

-- 5. Create Functions & Triggers
-- Function to automatically update the 'updated_at' timestamp
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_products_modtime
BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_orders_modtime
BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE PROCEDURE update_modified_column();


-- 6. Seed Data (Optional - Run to populate mock data)
INSERT INTO public.products (id, name, description, size, durability, surface_type, price, stock, image_url, category)
VALUES 
    ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'EFZ Pro Match Football', 'Premium match ball designed for precision and durability on natural grass.', 'Size 5', 'High (PU material)', 'Natural Grass / Turf', 45.00, 120, 'https://images.unsplash.com/photo-1614632537190-23e4146777db?auto=format&fit=crop&q=80&w=800', 'Football'),
    ('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'EFZ Elite Futsal', 'Low bounce futsal ball with superior control for fast-paced indoor games.', 'Size 4 (Futsal)', 'Extreme (Textured PU)', 'Indoor / Hard Court', 40.00, 250, 'https://images.unsplash.com/photo-1543152507-64010996fb28?auto=format&fit=crop&q=80&w=800', 'Futsal'),
    ('c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', 'EFZ Training Standard', 'Reliable training ball for daily use by academies and schools.', 'Size 5', 'Medium (PVC)', 'All Surfaces', 25.00, 500, 'https://images.unsplash.com/photo-1511886929837-354d827aae26?auto=format&fit=crop&q=80&w=800', 'Football');
