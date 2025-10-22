-- Таблица типов блюд
CREATE TABLE dish_types (
    type_id SERIAL PRIMARY KEY,
    type_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT DEFAULT 'Описание отсутствует',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Таблица блюд
CREATE TABLE dishes (
    dish_id SERIAL PRIMARY KEY,
    dish_name VARCHAR(200) NOT NULL UNIQUE,
    price DECIMAL(10,2) NOT NULL CHECK (price > 0),
    type_id INTEGER NOT NULL,
    cooking_time INTEGER DEFAULT 30 CHECK (cooking_time > 0),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (type_id) REFERENCES dish_types(type_id) ON DELETE RESTRICT
);

-- Таблица состава блюд (связь блюда и компонентов)
CREATE TABLE dish_composition (
    composition_id SERIAL PRIMARY KEY,
    dish_id INTEGER NOT NULL,
    ingredient_id INTEGER NOT NULL,
    quantity DECIMAL(8,2) NOT NULL CHECK (quantity > 0),
    unit VARCHAR(20) DEFAULT 'г',
    preparation_notes TEXT,
    FOREIGN KEY (dish_id) REFERENCES dishes(dish_id) ON DELETE CASCADE,
    FOREIGN KEY (ingredient_id) REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    UNIQUE(dish_id, ingredient_id)
);

-- Таблица компонентов
CREATE TABLE ingredients (
    ingredient_id SERIAL PRIMARY KEY,
    ingredient_name VARCHAR(200) NOT NULL UNIQUE,
    calories DECIMAL(8,2) NOT NULL CHECK (calories >= 0),
    price DECIMAL(10,2) NOT NULL CHECK (price >= 0),
    weight DECIMAL(8,2) NOT NULL CHECK (weight > 0),
    is_available BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Таблица состава компонентов (связь компонентов и микроэлементов)
CREATE TABLE ingredient_micronutrients (
    relation_id SERIAL PRIMARY KEY,
    ingredient_id INTEGER NOT NULL,
    micronutrient_id INTEGER NOT NULL,
    amount_per_100g DECIMAL(10,3) NOT NULL CHECK (amount_per_100g >= 0),
    FOREIGN KEY (ingredient_id) REFERENCES ingredients(ingredient_id) ON DELETE CASCADE,
    FOREIGN KEY (micronutrient_id) REFERENCES micronutrients(micronutrient_id) ON DELETE CASCADE,
    UNIQUE(ingredient_id, micronutrient_id)
);

-- Таблица микроэлементов
CREATE TABLE micronutrients (
    micronutrient_id SERIAL PRIMARY KEY,
    micronutrient_name VARCHAR(100) NOT NULL UNIQUE,
    unit VARCHAR(20) DEFAULT 'мг',
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Таблица суточной нормы микроэлементов
CREATE TABLE daily_micronutrient_norms (
    norm_id SERIAL PRIMARY KEY,
    micronutrient_id INTEGER NOT NULL,
    daily_amount DECIMAL(10,3) NOT NULL CHECK (daily_amount > 0),
    age_group VARCHAR(50) DEFAULT 'Взрослые',
    gender VARCHAR(10) DEFAULT 'Универсальный',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (micronutrient_id) REFERENCES micronutrients(micronutrient_id) ON DELETE CASCADE,
    UNIQUE(micronutrient_id, age_group, gender)
);

-- Индексы для улучшения производительности
CREATE INDEX idx_dishes_type_id ON dishes(type_id);
CREATE INDEX idx_dishes_price ON dishes(price);
CREATE INDEX idx_dishes_active ON dishes(is_active);

CREATE INDEX idx_dish_composition_dish_id ON dish_composition(dish_id);
CREATE INDEX idx_dish_composition_ingredient_id ON dish_composition(ingredient_id);

CREATE INDEX idx_ingredients_calories ON ingredients(calories);
CREATE INDEX idx_ingredients_price ON ingredients(price);
CREATE INDEX idx_ingredients_available ON ingredients(is_available);

CREATE INDEX idx_ingredient_micronutrients_ingredient ON ingredient_micronutrients(ingredient_id);
CREATE INDEX idx_ingredient_micronutrients_micronutrient ON ingredient_micronutrients(micronutrient_id);

CREATE INDEX idx_daily_norms_micronutrient ON daily_micronutrient_norms(micronutrient_id);

-- по одной таблице: активные блюда
CREATE VIEW active_dishes_view AS
SELECT dish_id, dish_name, price, cooking_time
FROM dishes
WHERE is_active = TRUE
ORDER BY price;

-- по нескольким таблицам: полная информация о блюдах
CREATE VIEW dish_details_view AS
SELECT 
    d.dish_id,
    d.dish_name,
    d.price AS dish_price,
    d.cooking_time,
    dt.type_name,
    COUNT(dc.ingredient_id) AS ingredient_count,
    SUM(i.calories * dc.quantity / 100) AS estimated_calories
FROM dishes d
JOIN dish_types dt ON d.type_id = dt.type_id
LEFT JOIN dish_composition dc ON d.dish_id = dc.dish_id
LEFT JOIN ingredients i ON dc.ingredient_id = i.ingredient_id
WHERE d.is_active = TRUE
GROUP BY d.dish_id, d.dish_name, d.price, d.cooking_time, dt.type_name;

-- типы блюд с дорогими блюдами
CREATE VIEW expensive_dish_types_view AS
SELECT 
    dt.type_name,
    COUNT(d.dish_id) AS total_dishes,
    AVG(d.price) AS avg_price,
    MAX(d.price) AS max_price
FROM dish_types dt
JOIN dishes d ON dt.type_id = d.type_id
WHERE d.is_active = TRUE
GROUP BY dt.type_id, dt.type_name
HAVING AVG(d.price) > 500
ORDER BY avg_price DESC;

-- VIEW для анализа питательной ценности блюд
CREATE VIEW dish_nutrition_view AS
SELECT 
    d.dish_id,
    d.dish_name,
    SUM(i.calories * dc.quantity / 100) AS total_calories,
    JSON_OBJECT_AGG(
        m.micronutrient_name, 
        (im.amount_per_100g * dc.quantity / 100)
    ) AS micronutrients
FROM dishes d
JOIN dish_composition dc ON d.dish_id = dc.dish_id
JOIN ingredients i ON dc.ingredient_id = i.ingredient_id
JOIN ingredient_micronutrients im ON i.ingredient_id = im.ingredient_id
JOIN micronutrients m ON im.micronutrient_id = m.micronutrient_id
GROUP BY d.dish_id, d.dish_name;


-- Триггер для автоматического обновления времени изменения суточной нормы
CREATE OR REPLACE FUNCTION update_daily_norm_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_daily_norm
    BEFORE UPDATE ON daily_micronutrient_norms
    FOR EACH ROW
    EXECUTE FUNCTION update_daily_norm_timestamp();

-- Триггер для обновления калорийности 
ALTER TABLE dishes ADD COLUMN total_calories DECIMAL(10,2) DEFAULT 0;

CREATE OR REPLACE FUNCTION update_dish_calories()
RETURNS TRIGGER AS $$
BEGIN
    -- Обновляем общую калорийность блюда при изменении состава
    UPDATE dishes 
    SET total_calories = (
        SELECT COALESCE(SUM(i.calories * dc.quantity / 100), 0)
        FROM dish_composition dc
        JOIN ingredients i ON dc.ingredient_id = i.ingredient_id
        WHERE dc.dish_id = COALESCE(NEW.dish_id, OLD.dish_id)
    )
    WHERE dish_id = COALESCE(NEW.dish_id, OLD.dish_id);
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_dish_calories_insert
    AFTER INSERT OR UPDATE ON dish_composition
    FOR EACH ROW
    EXECUTE FUNCTION update_dish_calories();

CREATE TRIGGER trigger_update_dish_calories_delete
    AFTER DELETE ON dish_composition
    FOR EACH ROW
    EXECUTE FUNCTION update_dish_calories();

-- Триггер для проверки доступности компонентов при добавлении блюда в меню
CREATE OR REPLACE FUNCTION check_ingredients_availability()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_active = TRUE THEN
        IF EXISTS (
            SELECT 1 
            FROM dish_composition dc
            JOIN ingredients i ON dc.ingredient_id = i.ingredient_id
            WHERE dc.dish_id = NEW.dish_id AND i.is_available = FALSE
        ) THEN
            RAISE EXCEPTION 'Нельзя активировать блюдо с недоступными ингредиентами';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_check_ingredients_availability
    BEFORE UPDATE OF is_active ON dishes
    FOR EACH ROW
    EXECUTE FUNCTION check_ingredients_availability();