export type Product = {
  id: string;
  name: string;
  description: string;
  size: string;
  durability: string;
  surfaceType: string;
  isWholesale: boolean;
  price: number; // Legacy alias for sellingPrice
  costPrice: number;
  sellingPrice: number;
  stock: number;
  lowStockThreshold: number;
  imageUrl: string;
  category: "Football" | "Futsal" | "Accessories";
};

export const MOCK_PRODUCTS: Product[] = [
  {
    id: "p1",
    name: "EFZ Pro Match Football",
    description: "Premium match ball designed for precision and durability on natural grass.",
    size: "Size 5",
    durability: "High (PU material)",
    surfaceType: "Natural Grass / Turf",
    isWholesale: true,
    price: 45.0,
    costPrice: 28.0,
    sellingPrice: 45.0,
    stock: 120,
    lowStockThreshold: 150,
    imageUrl: "https://images.unsplash.com/photo-1614632537190-23e4146777db?auto=format&fit=crop&q=80&w=800",
    category: "Football",
  },
  {
    id: "p2",
    name: "EFZ Elite Futsal",
    description: "Low bounce futsal ball with superior control for fast-paced indoor games.",
    size: "Size 4 (Futsal)",
    durability: "Extreme (Textured PU)",
    surfaceType: "Indoor / Hard Court",
    isWholesale: true,
    price: 40.0,
    costPrice: 24.0,
    sellingPrice: 40.0,
    stock: 250,
    lowStockThreshold: 100,
    imageUrl: "https://images.unsplash.com/photo-1553531384-cc64ac80f931?auto=format&fit=crop&q=80&w=800",
    category: "Futsal",
  },
  {
    id: "p3",
    name: "EFZ Training Standard",
    description: "Reliable training ball for daily use by academies and schools.",
    size: "Size 5",
    durability: "Medium (PVC)",
    surfaceType: "All Surfaces",
    isWholesale: true,
    price: 25.0,
    costPrice: 15.0,
    sellingPrice: 25.0,
    stock: 500,
    lowStockThreshold: 150,
    imageUrl: "https://images.unsplash.com/photo-1511886929837-354d827aae26?auto=format&fit=crop&q=80&w=800",
    category: "Football",
  },
  {
    id: "p4",
    name: "EFZ Futsal Training",
    description: "Durable futsal ball perfect for arena rentals and team training.",
    size: "Size 4 (Futsal)",
    durability: "High",
    surfaceType: "Indoor / Hard Court",
    isWholesale: true,
    price: 30.0,
    costPrice: 18.0,
    sellingPrice: 30.0,
    stock: 300,
    lowStockThreshold: 100,
    imageUrl: "https://images.unsplash.com/photo-1606925797300-0b35e9d1794e?auto=format&fit=crop&q=80&w=800",
    category: "Futsal",
  },
];

export const MOCK_TESTIMONIALS = [
  {
    id: "t1",
    name: "Ahmed Ali",
    role: "Arena Manager, Mogadishu",
    content: "EFZ futsal balls have significantly reduced our replacement costs. They withstand daily heavy use perfectly.",
  },
  {
    id: "t2",
    name: "Hassan Sports Academy",
    role: "Football School",
    content: "The quality of the Pro Match footballs is unmatched. Our players love the feel and precision.",
  },
  {
    id: "t3",
    name: "Somali Futsal League",
    role: "Tournament Organizer",
    content: "We use EFZ for all our official matches. The low bounce and durability are exactly what we need.",
  },
];
